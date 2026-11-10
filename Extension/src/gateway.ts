// Talks to Clew's Gateway on 127.0.0.1 (ARCHITECTURE §6). Before sending its token,
// the extension asks Clew to prove itself: `hello` must return HMAC(secret, nonce).
// A process squatting on the port cannot, so it never sees the token.

import {
  isFailure,
  isHello,
  isImportResponse,
  isPairResponse,
  PORTS,
  type ImportRequest,
  type ImportResponse,
  type PairResponse,
} from "./contract";

export interface Pairing {
  clientId: string;
  token: string;
  secret: string;
  /** Where Clew answered last time; tried first. */
  port: number;
}

export type Fetch = (url: string, init?: RequestInit) => Promise<Response>;

export class GatewayError extends Error {
  constructor(
    readonly kind: "unreachable" | "revoked" | "turnedOff" | "refused" | "badAnswer",
    message: string,
    readonly status?: number,
  ) {
    super(message);
  }
}

const PROBE_TIMEOUT_MS = 1500;
/** Never follow redirects: a squatter could bounce `hello` to the real Clew, get its
 * proof, and then receive the token on its own port. */
const NO_REDIRECTS = { redirect: "error" } as const;

export function base64url(bytes: Uint8Array): string {
  let s = "";
  for (const b of bytes) s += String.fromCharCode(b);
  return btoa(s).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

export function fromBase64url(s: string): Uint8Array<ArrayBuffer> {
  const b = atob(s.replace(/-/g, "+").replace(/_/g, "/") + "===".slice((s.length + 3) % 4));
  return Uint8Array.from(b, (c) => c.charCodeAt(0));
}

export function newNonce(): string {
  return base64url(crypto.getRandomValues(new Uint8Array(16)));
}

export async function hmac(secret: string, message: string): Promise<string> {
  const key = await crypto.subtle.importKey("raw", fromBase64url(secret), { name: "HMAC", hash: "SHA-256" }, false, [
    "sign",
  ]);
  return base64url(new Uint8Array(await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(message))));
}

export class Gateway {
  constructor(private readonly fetchFn: Fetch) {}

  /** The port of a Clew that proved itself to `pairing`, or (unpaired) any Clew. */
  async find(pairing?: Pairing): Promise<number> {
    const order = pairing ? [pairing.port, ...PORTS.filter((p) => p !== pairing.port)] : [...PORTS];
    let unknownToClew = false;
    for (const port of order) {
      const nonce = newNonce();
      const query = `nonce=${nonce}` + (pairing ? `&client=${encodeURIComponent(pairing.clientId)}` : "");
      let hello: unknown;
      try {
        const r = await this.fetchFn(`http://127.0.0.1:${port}/v1/hello?${query}`, {
          ...NO_REDIRECTS,
          signal: AbortSignal.timeout(PROBE_TIMEOUT_MS),
        });
        if (!r.ok) continue;
        hello = await r.json();
      } catch {
        continue;
      }
      if (!isHello(hello)) continue;
      if (!pairing) return port;
      if (hello.proof !== undefined && hello.proof === (await hmac(pairing.secret, nonce))) return port;
      // No proof: a Clew that no longer knows us (removed in Settings), or something
      // pretending to be Clew. Keep looking; never send the token here.
      if (hello.proof === undefined) unknownToClew = true;
    }
    if (unknownToClew) throw new GatewayError("revoked", "Clew doesn't know this browser anymore");
    throw new GatewayError("unreachable", "Clew isn't running");
  }

  async pair(code: string, name: string): Promise<Pairing> {
    const port = await this.find();
    const r = await this.fetchFn(`http://127.0.0.1:${port}/v1/pair`, {
      ...NO_REDIRECTS,
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ code, name }),
    });
    const body: unknown = await r.json().catch(() => undefined);
    if (!r.ok) throw new GatewayError("refused", isFailure(body) ? body.error : `HTTP ${r.status}`, r.status);
    if (!isPairResponse(body)) throw new GatewayError("badAnswer", "unexpected answer");
    const paired: PairResponse = body;
    return { clientId: paired.clientId, token: paired.token, secret: paired.secret, port };
  }

  /** Sends a scan. Returns the answer and the port Clew was found on. */
  async importList(pairing: Pairing, request: ImportRequest): Promise<{ response: ImportResponse; port: number }> {
    const port = await this.find(pairing);
    const r = await this.fetchFn(`http://127.0.0.1:${port}/v1/import`, {
      ...NO_REDIRECTS,
      method: "POST",
      headers: { "Content-Type": "application/json", Authorization: `Bearer ${pairing.token}` },
      body: JSON.stringify(request),
    });
    const body: unknown = await r.json().catch(() => undefined);
    if (r.status === 401) throw new GatewayError("revoked", "Clew doesn't know this browser anymore", 401);
    // The user turned this list off in Clew's Settings.
    if (r.status === 409) throw new GatewayError("turnedOff", "list turned off in Clew", 409);
    if (!r.ok) throw new GatewayError("refused", isFailure(body) ? body.error : `HTTP ${r.status}`, r.status);
    if (!isImportResponse(body)) throw new GatewayError("badAnswer", "unexpected answer");
    return { response: body, port };
  }
}
