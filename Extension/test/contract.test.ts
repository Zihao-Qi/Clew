// The same files the Swift ContractTests decode (Contract/v1/README.md).
import { describe, expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { isBookmarkResponse, isFailure, isHello, isImportResponse, isPairResponse, type ImportRequest, type PairRequest } from "../src/contract";
import { BookmarkScan, bookmarkClick, readWindow } from "../src/x";
import { hmac } from "../src/gateway";
import { scanWatchLater } from "../src/youtube";
import { parseHTML } from "linkedom";

const example = (name: string): unknown =>
  JSON.parse(readFileSync(new URL(`../../Contract/v1/${name}`, import.meta.url), "utf8"));
const keys = (v: unknown): string[] =>
  typeof v === "object" && v !== null && !Array.isArray(v)
    ? Object.entries(v).flatMap(([k, x]) => [k, ...keys(x).map((s) => `${k}.${s}`)]).sort()
    : Array.isArray(v) && v.length > 0
      ? keys(v[0]).map((s) => `[].${s}`)
      : [];

describe("contract", () => {
  test("Clew's answers pass the extension's checks", () => {
    expect(isHello(example("hello.response.json"))).toBe(true);
    expect(isPairResponse(example("pair.response.json"))).toBe(true);
    expect(isImportResponse(example("import.response.json"))).toBe(true);
    expect(isImportResponse(example("import-x.response.json"))).toBe(true);
    expect(isImportResponse(example("import-x-end.response.json"))).toBe(true);
    expect(isBookmarkResponse(example("bookmark.response.json"))).toBe(true);
    expect(isFailure(example("failure.response.json"))).toBe(true);
  });

  test("the checks reject answers that drift", () => {
    const r = example("import.response.json") as { result: Record<string, unknown> };
    delete r.result.letGo;
    expect(isImportResponse(r)).toBe(false);
    const b = example("bookmark.response.json") as Record<string, unknown>;
    delete b.listCount;
    expect(isBookmarkResponse(b)).toBe(false);
    expect(isHello({ app: "other", api: 1 })).toBe(false);
  });

  test("requests have exactly the example's fields", () => {
    const pair: PairRequest = { code: "1", name: "Chrome" };
    expect(keys(pair)).toEqual(keys(example("pair.request.json")));
    const { document } = parseHTML(readFileSync(new URL("fixtures/watch-later.synthetic.html", import.meta.url), "utf8"));
    const scan: ImportRequest = scanWatchLater(document);
    expect(keys(scan)).toEqual(keys(example("import.request.json")));
    const x = parseHTML(readFileSync(new URL("fixtures/x-bookmarks.synthetic.html", import.meta.url), "utf8")).document;
    const xScan = new BookmarkScan();
    xScan.add(readWindow(x, (h) => h));
    expect(keys(xScan.request())).toEqual(keys(example("import-x.request.json")));
    // SPEC 2026-11-13: a whole scan (every row readable) whose end was seen says so.
    const whole = new BookmarkScan();
    whole.add({ atTop: true, posts: readWindow(x, (h) => h).posts.filter((p) => p !== undefined) });
    expect(keys(whole.request(true))).toEqual(keys(example("import-x-end.request.json")));
    const click = bookmarkClick(x.getElementById("icon")!, (h) => h);
    expect(keys(click)).toEqual(keys(example("bookmark.request.json")));
  });

  test("HMAC matches a fixed vector (Swift's ContractTests checks the same one)", async () => {
    // HMAC-SHA256(key "secret" = base64url "c2VjcmV0", "abcdefghijklmnop"), from Python's hmac.
    expect(await hmac("c2VjcmV0", "abcdefghijklmnop")).toBe("khZw39NRSnJr9gReScOR4gC1Ho_Nev73PUGL2JjG0V0");
  });
});
