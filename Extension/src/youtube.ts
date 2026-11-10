// YouTube Watch Later scraper. Quarantined: every selector lives in SELECTORS, and
// tests run against saved page snapshots (ARCHITECTURE §6). When YouTube changes its
// page, update the table and bump SELECTOR_VERSION.

import type { ExternalEntry, ImportRequest } from "./contract";

export const SELECTOR_VERSION = "youtube-2026-11-09c";

export const SELECTORS = {
  /** One per video in the list. */
  row: "ytd-playlist-video-renderer",
  /** Inside a row: the title link, href `/watch?v=<id>&list=WL&index=<n>`. */
  titleLink: "a#video-title",
  /** Inside a row: the red "watched" bar on the thumbnail, `style="width: 11%"`.
   * Absent when the video was never started. First one seen on the Watch Later page
   * 2026-11-09; the second seen on YouTube 2026-11-08. */
  progress: [
    "ytw-thumbnail-overlay-resume-playback-renderer .ytwThumbnailOverlayResumePlaybackRendererThumbnailOverlayResumePlaybackProgress",
    ".ytThumbnailOverlayProgressBarHostWatchedProgressBarSegment",
  ],
  /** Text holding the list's own count, e.g. "12 videos" or "No videos". Only
   * selectors seen on the real page (2026-11-09): a broad guess could pick up some
   * other "3 videos" and make a partial page look whole. */
  count: [
    "ytd-playlist-byline-renderer yt-formatted-string.byline-item",
    "ytd-playlist-header-renderer .metadata-stats yt-formatted-string",
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

/** "width: 11%" → 0.11; undefined unless it is a percentage from 0 to 100. */
export function parseProgress(style: string | null): number | undefined {
  const m = /(?:^|;)\s*width:\s*(\d{1,3}(?:\.\d+)?)%/i.exec(style ?? "");
  if (!m?.[1]) return undefined;
  const pct = Number(m[1]);
  return pct >= 0 && pct <= 100 ? Math.round(pct) / 100 : undefined;
}

function rowProgress(row: Element): number | undefined {
  for (const selector of SELECTORS.progress) {
    const bar = row.querySelector(selector);
    if (bar) return parseProgress(bar.getAttribute("style"));
  }
  return undefined;
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
    if (!id || !title) continue;
    const progress = rowProgress(row);
    entries.push(progress === undefined ? { externalRef: id, title } : { externalRef: id, title, progress });
  }
  const total = listTotal(root);
  return {
    source: "extension.youtube",
    ...(total === undefined ? {} : { listTotal: total }),
    entries,
    scan: { found: rows.length, parsed: entries.length, selectorVersion: SELECTOR_VERSION },
  };
}
