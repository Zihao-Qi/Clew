// YouTube Watch Later scraper. Quarantined: every selector lives in SELECTORS, and
// tests run against saved page snapshots (ARCHITECTURE §6). When YouTube changes its
// page, update the table and bump SELECTOR_VERSION.

import type { ExternalEntry, ImportRequest } from "./contract";

export const SELECTOR_VERSION = "youtube-2026-11-09";

export const SELECTORS = {
  /** One per video in the list. */
  row: "ytd-playlist-video-renderer",
  /** Inside a row: the title link, href `/watch?v=<id>&list=WL&index=<n>`. */
  titleLink: "a#video-title",
  /** Text holding the list's own count, e.g. "12 videos" or "No videos". */
  count: [
    "ytd-playlist-byline-renderer yt-formatted-string.byline-item",
    "ytd-playlist-header-renderer .metadata-stats yt-formatted-string",
    "yt-page-header-view-model yt-content-metadata-view-model span",
    "ytd-playlist-sidebar-primary-info-renderer #stats yt-formatted-string",
  ],
} as const;

const VIDEO_ID = /^[A-Za-z0-9_-]{11}$/;

export function isWatchLater(url: string): boolean {
  try {
    const u = new URL(url);
    return u.hostname === "www.youtube.com" && u.pathname === "/playlist" && u.searchParams.get("list") === "WL";
  } catch {
    return false;
  }
}

export function videoId(href: string | null): string | undefined {
  if (!href) return undefined;
  try {
    const id = new URL(href, "https://www.youtube.com").searchParams.get("v") ?? "";
    return VIDEO_ID.test(id) ? id : undefined;
  } catch {
    return undefined;
  }
}

/** "1,234 videos" → 1234, "No videos" → 0; undefined when no count is readable. */
export function parseCount(text: string): number | undefined {
  const t = text.replace(/\s+/g, " ").trim();
  if (/^no videos?$/i.test(t)) return 0;
  const m = /^([\d,.\u00a0 ]+) videos?$/i.exec(t);
  if (!m?.[1]) return undefined;
  const n = Number(m[1].replace(/[,.\u00a0 ]/g, ""));
  return Number.isSafeInteger(n) ? n : undefined;
}

export function listTotal(root: ParentNode): number | undefined {
  for (const selector of SELECTORS.count) {
    for (const el of Array.from(root.querySelectorAll(selector))) {
      const n = parseCount(el.textContent ?? "");
      if (n !== undefined) return n;
    }
  }
  return undefined;
}

/** Reads the Watch Later list as currently loaded on the page. */
export function scanWatchLater(root: ParentNode): ImportRequest {
  const rows = Array.from(root.querySelectorAll(SELECTORS.row));
  const entries: ExternalEntry[] = [];
  for (const row of rows) {
    const link = row.querySelector(SELECTORS.titleLink);
    const id = videoId(link?.getAttribute("href") ?? null);
    const title = (link?.getAttribute("title") || link?.textContent || "").replace(/\s+/g, " ").trim();
    if (id && title) entries.push({ externalRef: id, title });
  }
  const total = listTotal(root);
  return {
    source: "extension.youtube",
    ...(total === undefined ? {} : { listTotal: total }),
    entries,
    scan: { found: rows.length, parsed: entries.length, selectorVersion: SELECTOR_VERSION },
  };
}
