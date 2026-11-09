// Service worker: the only part that talks to Clew. The content script sends scans
// here; the popup pairs and reads the status.

import type { ImportRequest } from "./contract";
import { Gateway, GatewayError, type Pairing } from "./gateway";

export interface Status {
  at: number;
  ok: boolean;
  /** "unreachable" → "Open Clew"; "revoked" → pair again. */
  problem?: "unreachable" | "revoked" | "refused" | "badAnswer";
  added?: number;
  letGo?: number;
  laterCount?: number;
  needsUpdate?: boolean;
}

export type Message =
  | { type: "watchLater"; scan: ImportRequest }
  | { type: "pair"; code: string }
  | { type: "forget" }
  | { type: "status" };

export type StatusAnswer = { paired: boolean; status?: Status };

const gateway = new Gateway((url, init) => fetch(url, init));

async function load(): Promise<{ pairing?: Pairing; status?: Status; lastScan?: string; lastScanAt?: number }> {
  return (await chrome.storage.local.get(["pairing", "status", "lastScan", "lastScanAt"])) as never;
}

/** The same scan again within a minute is not sent twice (the list re-renders often). */
const RESEND_AFTER_MS = 60_000;

async function sendScan(scan: ImportRequest): Promise<Status | undefined> {
  const { pairing, lastScan, lastScanAt } = await load();
  if (!pairing) return undefined;
  const key = JSON.stringify(scan);
  if (key === lastScan && Date.now() - (lastScanAt ?? 0) < RESEND_AFTER_MS) return undefined;
  let status: Status;
  try {
    const { response, port } = await gateway.importList(pairing, scan);
    status = {
      at: Date.now(),
      ok: true,
      added: response.result.added,
      letGo: response.result.letGo,
      laterCount: response.laterCount,
      needsUpdate: response.needsUpdate,
    };
    await chrome.storage.local.set({ pairing: { ...pairing, port }, lastScan: key, lastScanAt: Date.now() });
  } catch (e) {
    const problem = e instanceof GatewayError ? e.kind : "unreachable";
    status = { at: Date.now(), ok: false, problem };
  }
  await chrome.storage.local.set({ status });
  return status;
}

async function handle(message: Message): Promise<unknown> {
  switch (message.type) {
    case "watchLater":
      return sendScan(message.scan);
    case "pair": {
      try {
        const pairing = await gateway.pair(message.code, "Chrome");
        await chrome.storage.local.set({ pairing });
        await chrome.storage.local.remove(["status", "lastScan", "lastScanAt"]);
        return { ok: true };
      } catch (e) {
        if (e instanceof GatewayError && e.kind === "refused") return { ok: false, problem: "code", status: e.status };
        return { ok: false, problem: e instanceof GatewayError ? e.kind : "unreachable" };
      }
    }
    case "forget":
      await chrome.storage.local.clear();
      return { ok: true };
    case "status": {
      const { pairing, status } = await load();
      return { paired: !!pairing, status } satisfies StatusAnswer;
    }
  }
}

chrome.runtime.onMessage.addListener((message: Message, sender, reply) => {
  // Only this extension's own pages and content scripts.
  if (sender.id !== chrome.runtime.id) return false;
  handle(message).then(reply, () => reply(undefined));
  return true; // answers asynchronously
});
