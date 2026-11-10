// X bookmarks reader. Quarantined like youtube.ts: every selector lives in SELECTORS,
// and tests run against saved snapshots (ARCHITECTURE §6).
//
// The Bookmarks page has no count and keeps only the rows near the screen (it drops
// rows as you scroll), so a scan is built up as the page scrolls. Only the stretch seen
// without a break from the very top is sent as `fromTop`: Clew compares that stretch
// with the order it last saw (the gap rule). Rows seen after a break are added, never
// compared.

import type { BookmarkRequest, ExternalEntry, ImportRequest } from "./contract";

// Checked on the signed-in page 2026-11-10: Bookmarks now lives at /i/history (a
// "Bookmarks" tab; /i/history/likes is Likes), rows are cellInnerDiv with
// translateY (fractions too), posts are article[data-testid="tweet"] with their own
// time link, quotes sit in div[role="link"], and the button is a <button> with
// data-testid "bookmark" or "removeBookmark". X Articles have no tweetText: their
// title is the first text in the card around "article-cover-image".
export const SELECTOR_VERSION = "x-2026-11-10b";

export const SELECTORS = {
  /** One per row of the timeline, `style="transform: translateY(<n>px); …"`. */
  cell: '[data-testid="cellInnerDiv"]',
  /** A post inside a row (or anywhere on x.com). */
  post: 'article[data-testid="tweet"]',
  /** The post's text; a quoted post has its own, inside a `div[role="link"]`. */
  text: '[data-testid="tweetText"]',
  /** Name and @handle at the top of a post. */
  userName: '[data-testid="User-Name"]',
  /** The bookmark button when the post is not bookmarked / when it is. */
  bookmark: '[data-testid="bookmark"]',
  unbookmark: '[data-testid="removeBookmark"]',
  /** The quoted post's box inside a post. */
  quote: 'div[role="link"]',
  /** An X Article's cover image; its card's first text is the article's title. */
  articleCover: '[data-testid="article-cover-image"]',
  /** Text blocks (the article title is the first one in the card). */
  textBlock: '[dir="auto"]',
} as const;

const STATUS = /^\/[A-Za-z0-9_]{1,15}\/status\/(\d{1,19})(?:[/?#]|$)/;
const HANDLE = /^\/([A-Za-z0-9_]{1,15})\/status\//;

/** The Bookmarks page: /i/history (its Bookmarks tab, seen 2026-11-10) or the older
 * /i/bookmarks. Never the Likes tab. */
export function isBookmarks(url: string): boolean {
  try {
    const u = new URL(url);
    return (
      (u.hostname === "x.com" || u.hostname === "twitter.com") &&
      (u.pathname === "/i/history" || u.pathname === "/i/bookmarks")
    );
  } catch {
    return false;
  }
}

/** The post's own status link: the one around its time stamp (a quoted post has its
 * own time link too, inside the quote box). */
function statusLink(post: Element): string | undefined {
  for (const time of Array.from(post.querySelectorAll("time"))) {
    const link = time.closest("a");
    if (!link || inQuote(post, link)) continue;
    const href = link.getAttribute("href") ?? "";
    if (STATUS.test(href)) return href;
  }
  return undefined;
}

function inQuote(post: Element, el: Element): boolean {
  const box = el.closest(SELECTORS.quote);
  return box !== null && post.contains(box);
}

export function postId(post: Element): string | undefined {
  const id = STATUS.exec(statusLink(post) ?? "")?.[1];
  return id && !id.startsWith("0") ? id : undefined;
}

/** The post's own text (not a quoted post's), whitespace collapsed. */
export function postText(post: Element): string {
  const own = Array.from(post.querySelectorAll(SELECTORS.text)).find((t) => !inQuote(post, t));
  return (own?.textContent ?? "").replace(/\s+/g, " ").trim();
}

/** An X Article's title (the article this post shares), not a quoted post's. */
export function articleTitle(post: Element): string | undefined {
  const cover = post.querySelector(SELECTORS.articleCover);
  if (!cover || inQuote(post, cover)) return undefined;
  for (let el = cover.parentElement; el && el !== post; el = el.parentElement) {
    const block = Array.from(el.querySelectorAll(SELECTORS.textBlock)).find(
      (d) => !d.closest(SELECTORS.userName) && (d.textContent ?? "").trim() !== "",
    );
    if (block) return (block.textContent ?? "").replace(/\s+/g, " ").trim();
  }
  return undefined;
}

export function postHandle(post: Element): string | undefined {
  return HANDLE.exec(statusLink(post) ?? "")?.[1];
}

/** A post as an entry: the title of the X Article it shares, else its own text, else
 * "Post by @name" (`postBy`). */
export function readPost(post: Element, postBy: (handle: string) => string): ExternalEntry | undefined {
  const id = postId(post);
  if (!id) return undefined;
  const handle = postHandle(post);
  const title = articleTitle(post) || postText(post) || (handle ? postBy(`@${handle}`) : "");
  return title ? { externalRef: id, title } : undefined;
}

/** The post shows the "Bookmark" button, so it is not bookmarked (any more). */
export function isUnbookmarked(post: Element): boolean {
  return post.querySelector(SELECTORS.bookmark) !== null && post.querySelector(SELECTORS.unbookmark) === null;
}

/** "transform: translateY(123px)" → 123. */
export function cellTop(cell: Element): number | undefined {
  const m = /translateY\((-?\d+(?:\.\d+)?)px\)/.exec(cell.getAttribute("style") ?? "");
  return m?.[1] === undefined ? undefined : Number(m[1]);
}

/** What one look at the page saw: the rows now in the page, top first. */
export interface Window {
  /** The first row is the top of the list. */
  atTop: boolean;
  /** Each post row: its entry, or undefined when it could not be read. */
  posts: (ExternalEntry | undefined)[];
}

export function readWindow(root: ParentNode, postBy: (handle: string) => string): Window {
  const cells = Array.from(root.querySelectorAll(SELECTORS.cell))
    .map((cell) => ({ cell, top: cellTop(cell) }))
    .sort((a, b) => (a.top ?? Infinity) - (b.top ?? Infinity));
  const posts: (ExternalEntry | undefined)[] = [];
  for (const { cell } of cells) {
    const post = cell.querySelector(SELECTORS.post);
    // Unbookmarked while on the page: X may keep showing it, but it is off the list.
    if (post && !isUnbookmarked(post)) posts.push(readPost(post, postBy));
  }
  return { atTop: cells.length > 0 && cells[0]?.top === 0, posts };
}

/** Builds one scan out of the windows seen while the page scrolls. */
export class BookmarkScan {
  private readonly entries: ExternalEntry[] = [];
  private readonly refs = new Set<string>();
  /** Entries in the unbroken run from the top. */
  private run = 0;
  private state: "waiting" | "running" | "broken" = "waiting";
  private unreadable = 0;

  add(window: Window): void {
    const readable = window.posts.filter((p): p is ExternalEntry => p !== undefined);
    this.unreadable += window.posts.length - readable.length;
    if (this.state === "waiting") {
      if (readable.length === 0) return;
      this.state = window.atTop ? "running" : "broken";
    } else if (this.state === "running" && !readable.some((p) => this.refs.has(p.externalRef))) {
      // Nothing in common with what was seen: the page jumped past some rows.
      this.state = "broken";
    }
    for (const p of readable) {
      if (this.refs.has(p.externalRef)) continue;
      this.refs.add(p.externalRef);
      this.entries.push(p);
      if (this.state === "running") this.run = this.entries.length;
    }
  }

  /** A post unbookmarked during this visit leaves the scan, so the next send does not
   * bring it back (it was seen 19 → 18 → 19 on 2026-11-10). */
  forget(ref: string): void {
    const i = this.entries.findIndex((e) => e.externalRef === ref);
    if (i < 0) return;
    this.entries.splice(i, 1);
    this.refs.delete(ref);
    if (i < this.run) this.run -= 1;
  }

  request(): ImportRequest {
    const parsed = this.entries.length;
    return {
      source: "extension.x",
      entries: [...this.entries],
      // A row that could not be read may be a post Clew knows: then nothing is compared.
      scan: { found: parsed + this.unreadable, parsed, selectorVersion: SELECTOR_VERSION },
      fromTop: this.run,
    };
  }
}

/** What a bookmark click means for the visit's scan: a post unbookmarked here leaves
 * it, so the next send does not bring it back. */
export function applyClick(scan: BookmarkScan | undefined, click: BookmarkRequest): void {
  if (!click.bookmarked) scan?.forget(click.entry.externalRef);
}

/** A click on a post's bookmark button: what changed. The button is read before X
 * flips it, so "bookmark" means it is being bookmarked. */
export function bookmarkClick(target: Element, postBy: (handle: string) => string): BookmarkRequest | undefined {
  const button = target.closest(`${SELECTORS.bookmark}, ${SELECTORS.unbookmark}`);
  const post = button?.closest(SELECTORS.post);
  if (!button || !post) return undefined;
  const bookmarked = button.matches(SELECTORS.bookmark);
  const entry = readPost(post, postBy);
  const id = postId(post);
  if (entry) return { source: "extension.x", entry, bookmarked };
  // Removing needs only the id.
  return !bookmarked && id ? { source: "extension.x", entry: { externalRef: id, title: "" }, bookmarked } : undefined;
}
