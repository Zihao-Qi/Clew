// Gateway /v1 wire types. Contract/v1/*.json is the contract; test/contract.test.ts
// checks these validators and the request builders against it (Contract/v1/README.md).

export const API_VERSION = 1;
/** Clew listens on the first free port of these. */
export const PORTS = [39271, 39272, 39273, 39274, 39275] as const;

export interface Hello {
  app: "clew";
  api: number;
  proof?: string;
}

export interface PairRequest {
  code: string;
  name: string;
}

export interface PairResponse {
  clientId: string;
  token: string;
  secret: string;
  scopes: string[];
}

export interface ExternalEntry {
  externalRef: string;
  title: string;
  /** How much was watched, 0–1, when the page shows it. */
  progress?: number;
}

export interface ScanReport {
  found: number;
  parsed: number;
  selectorVersion: string;
}

export type ListSource = "extension.youtube" | "extension.x";

export interface ImportRequest {
  source: ListSource;
  /** The page's own count (YouTube). */
  listTotal?: number;
  entries: ExternalEntry[];
  scan: ScanReport;
  /** X: how many leading entries were seen as one unbroken run from the top. */
  fromTop?: number;
  /** X: the list's end was seen, still and on screen, so the run is the whole list. */
  reachedEnd?: boolean;
}

/** `POST /v1/bookmark`: the bookmark button was clicked on a post. */
export interface BookmarkRequest {
  source: "extension.x";
  entry: ExternalEntry;
  /** False when the bookmark was removed. */
  bookmarked: boolean;
}

export interface ImportResult {
  added: number;
  renamed: number;
  restored: number;
  letGo: number;
  skipped: number;
  /** Videos whose watch progress changed. */
  progressed: number;
  complete: boolean;
}

export interface ImportResponse {
  result: ImportResult;
  needsUpdate: boolean;
  listCount: number;
}

export interface BookmarkResponse {
  result: ImportResult;
  listCount: number;
}

export interface Failure {
  error: string;
}

// Runtime checks: Clew's answers are parsed, never trusted as-is.

const isObject = (v: unknown): v is Record<string, unknown> => typeof v === "object" && v !== null && !Array.isArray(v);
const isInt = (v: unknown): v is number => typeof v === "number" && Number.isInteger(v) && v >= 0;

export function isHello(v: unknown): v is Hello {
  return isObject(v) && v.app === "clew" && isInt(v.api) && (v.proof === undefined || typeof v.proof === "string");
}

export function isPairResponse(v: unknown): v is PairResponse {
  return (
    isObject(v) &&
    typeof v.clientId === "string" &&
    typeof v.token === "string" &&
    typeof v.secret === "string" &&
    Array.isArray(v.scopes) &&
    v.scopes.every((s) => typeof s === "string")
  );
}

function isImportResult(r: unknown): r is ImportResult {
  return (
    isObject(r) &&
    ["added", "renamed", "restored", "letGo", "skipped", "progressed"].every((k) => isInt(r[k])) &&
    typeof r.complete === "boolean"
  );
}

export function isImportResponse(v: unknown): v is ImportResponse {
  return isObject(v) && typeof v.needsUpdate === "boolean" && isInt(v.listCount) && isImportResult(v.result);
}

export function isBookmarkResponse(v: unknown): v is BookmarkResponse {
  return isObject(v) && isInt(v.listCount) && isImportResult(v.result);
}

export function isFailure(v: unknown): v is Failure {
  return isObject(v) && typeof v.error === "string";
}
