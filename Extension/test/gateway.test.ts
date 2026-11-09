import { describe, expect, test } from "bun:test";
import { PORTS } from "../src/contract";
import { Gateway, GatewayError, hmac, type Pairing } from "../src/gateway";

const SECRET = "c2VjcmV0LXNlY3JldC1zZWNyZXQtc2VjcmV0LXNlYw";
const pairing: Pairing = { clientId: "6F9619FF-8B86-D011-B42D-00C04FC964FF", token: "tok", secret: SECRET, port: PORTS[0] };

type Server = (url: URL, init?: RequestInit) => Promise<Response> | Response;
const json = (status: number, body: unknown) => new Response(JSON.stringify(body), { status });

/** A fake loopback: each port answers with its own handler, or refuses the connection. */
function network(servers: Partial<Record<number, Server>>) {
  const calls: { url: URL; init?: RequestInit }[] = [];
  const fetchFn = async (raw: string, init?: RequestInit) => {
    const url = new URL(raw);
    calls.push({ url, init });
    const server = servers[Number(url.port)];
    if (!server) throw new TypeError("connection refused");
    return server(url, init);
  };
  return { fetchFn, calls };
}

/** A real Clew: proves itself with the shared secret, accepts the token. */
const clew: Server = async (url, init) => {
  if (url.pathname === "/v1/hello") {
    const nonce = url.searchParams.get("nonce")!;
    const proof = url.searchParams.get("client") ? await hmac(SECRET, nonce) : undefined;
    return json(200, { app: "clew", api: 1, ...(proof ? { proof } : {}) });
  }
  if (url.pathname === "/v1/import") {
    const auth = (init?.headers as Record<string, string>).Authorization;
    if (auth !== "Bearer tok") return json(401, { error: "unknown token" });
    return json(200, {
      result: { added: 1, renamed: 0, restored: 0, letGo: 0, skipped: 0, complete: true },
      needsUpdate: false,
      laterCount: 1,
    });
  }
  return json(404, { error: "not found" });
};

/** Something else on the port that says it is Clew but can't prove it. */
const impostor: Server = (url) =>
  url.pathname === "/v1/hello" ? json(200, { app: "clew", api: 1, proof: "forged" }) : json(200, {});

const scan = {
  source: "extension.youtube" as const,
  listTotal: 1,
  entries: [{ externalRef: "aaaaaaaaaaa", title: "A" }],
  scan: { found: 1, parsed: 1, selectorVersion: "t" },
};

describe("finding Clew", () => {
  test("the token goes only to a Clew that proved itself", async () => {
    const net = network({ [PORTS[0]]: impostor, [PORTS[2]]: clew });
    const { port } = await new Gateway(net.fetchFn).importList(pairing, scan);
    expect(port).toBe(PORTS[2]);
    const withToken = net.calls.filter((c) => (c.init?.headers as Record<string, string> | undefined)?.Authorization);
    expect(withToken.map((c) => Number(c.url.port))).toEqual([PORTS[2]]);
  });

  test("the proof is HMAC-SHA256 of this request's nonce", async () => {
    // A replayed proof (for another nonce) is refused.
    let replay: string | undefined;
    const recorder: Server = async (url) => {
      const proof = await hmac(SECRET, "some-earlier-nonce-xx");
      replay = proof;
      return url.pathname === "/v1/hello" ? json(200, { app: "clew", api: 1, proof }) : json(200, {});
    };
    const net = network({ [PORTS[0]]: recorder });
    await expect(new Gateway(net.fetchFn).find(pairing)).rejects.toMatchObject({ kind: "unreachable" });
    expect(replay).toBeDefined();
  });

  test("a Clew that no longer knows this browser is reported as revoked", async () => {
    const forgetful: Server = (url) => json(200, { app: "clew", api: 1 });
    const net = network({ [PORTS[1]]: forgetful });
    await expect(new Gateway(net.fetchFn).importList(pairing, scan)).rejects.toMatchObject({ kind: "revoked" });
    expect(net.calls.every((c) => c.url.pathname === "/v1/hello")).toBe(true);
  });

  test("nothing listening means Clew isn't running", async () => {
    const net = network({});
    const error = await new Gateway(net.fetchFn).find(pairing).catch((e) => e);
    expect(error).toBeInstanceOf(GatewayError);
    expect(error.kind).toBe("unreachable");
    expect(net.calls.length).toBe(PORTS.length);
  });

  test("the last known port is tried first", async () => {
    const net = network({ [PORTS[3]]: clew });
    await new Gateway(net.fetchFn).find({ ...pairing, port: PORTS[3] });
    expect(Number(net.calls[0]!.url.port)).toBe(PORTS[3]);
    expect(net.calls.length).toBe(1);
  });
});

describe("import", () => {
  test("a token Clew no longer accepts means pair again", async () => {
    // Clew proves itself (it still has the secret) but refuses the token.
    const stale: Server = async (url, init) =>
      url.pathname === "/v1/hello" ? clew(url, init) : json(401, { error: "unknown token" });
    const net = network({ [PORTS[0]]: stale });
    await expect(new Gateway(net.fetchFn).importList(pairing, scan)).rejects.toMatchObject({ kind: "revoked" });
  });

  test("Clew's answer comes back checked", async () => {
    const net = network({ [PORTS[0]]: clew });
    const { response } = await new Gateway(net.fetchFn).importList(pairing, scan);
    expect(response.laterCount).toBe(1);
  });
});

describe("pairing", () => {
  test("sends the code and keeps what Clew returns", async () => {
    const pairingServer: Server = (url, init) => {
      if (url.pathname === "/v1/hello") return json(200, { app: "clew", api: 1 });
      expect(JSON.parse(String(init?.body))).toEqual({ code: "482913", name: "Chrome" });
      return json(200, { clientId: "id", token: "t", secret: SECRET, scopes: ["import"] });
    };
    const net = network({ [PORTS[1]]: pairingServer });
    expect(await new Gateway(net.fetchFn).pair("482913", "Chrome")).toEqual({
      clientId: "id",
      token: "t",
      secret: SECRET,
      port: PORTS[1],
    });
  });

  test("a wrong code is refused with Clew's reason", async () => {
    const wrong: Server = (url) =>
      url.pathname === "/v1/hello" ? json(200, { app: "clew", api: 1 }) : json(403, { error: "wrong code" });
    const net = network({ [PORTS[0]]: wrong });
    await expect(new Gateway(net.fetchFn).pair("000000", "Chrome")).rejects.toMatchObject({
      kind: "refused",
      status: 403,
      message: "wrong code",
    });
  });
});
