// Runs on x.com. Two jobs, both light:
// - On the Bookmarks page, it reads the rows as you scroll (X keeps only the rows near
//   the screen) and sends the scan once the page settles.
// - Anywhere on x.com, a click on a post's bookmark button is sent at once: one click
//   listener, idle until you click.

import { BookmarkScan, applyClick, bookmarkClick, endRow, isBookmarks, readWindow } from "./x";

const SETTLE_MS = 1500;
const LOOK_MS = 250;
/** The end of the list must stay on screen, unchanged, this long (SPEC 2026-11-13). */
const END_STILL_MS = 3000;
/** ...and be seen this soon after the page loaded, so an old tab never says "whole". */
const VISIT_MS = 10 * 60_000;
const postBy = (handle: string) => chrome.i18n.getMessage("postBy", [handle]) || `Post by ${handle}`;

let scan: BookmarkScan | undefined;
let page = "";
let lookTimer: ReturnType<typeof setTimeout> | undefined;
let sendTimer: ReturnType<typeof setTimeout> | undefined;
let endTimer: ReturnType<typeof setTimeout> | undefined;
/** When this visit to Bookmarks began. */
let visitStart = 0;
/** Since when the end has been on screen, and what the page held then. */
let endSince: number | undefined;
let endKey = "";

/** After the extension is reloaded, this copy in an open tab is cut off; it goes quiet. */
function orphaned(): boolean {
  return !chrome.runtime?.id;
}

function stop(): void {
  clearTimeout(lookTimer);
  clearTimeout(sendTimer);
  clearTimeout(endTimer);
  observer.disconnect();
  document.removeEventListener("click", onClick, true);
  removeEventListener("scroll", look);
}

/** What the page holds now, so a change during the 3 seconds restarts the wait. */
function pageKey(current: BookmarkScan): string {
  return `${document.querySelectorAll('[data-testid="cellInnerDiv"]').length}:${current.size}`;
}

/** The end of the list is on screen now, with a whole scan behind it. */
function endInView(current: BookmarkScan): boolean {
  if (!current.whole || Date.now() - visitStart > VISIT_MS) return false;
  const row = endRow(document, postBy);
  if (!row) return false;
  const box = row.getBoundingClientRect();
  return box.top < innerHeight && box.bottom > 0;
}

/** The end has been on screen, unchanged, for END_STILL_MS: checked again right now. */
function endHeld(current: BookmarkScan): boolean {
  return endSince !== undefined && Date.now() - endSince >= END_STILL_MS && endInView(current)
    && pageKey(current) === endKey;
}

function sendNow(current: BookmarkScan): void {
  send({ type: "xBookmarks", scan: current.request(endHeld(current)) });
}

function send(message: unknown): void {
  try {
    chrome.runtime.sendMessage(message).catch(() => {});
  } catch {
    stop();
  }
}

/** Reads the rows now on the page into the scan (at most every LOOK_MS), and sends the
 * scan once the page has been still for SETTLE_MS. */
function look(): void {
  if (lookTimer !== undefined) return;
  lookTimer = setTimeout(() => {
    lookTimer = undefined;
    if (orphaned()) return stop();
    if (location.href !== page) {
      page = location.href;
      // A new visit to Bookmarks starts a new scan, from the top.
      scan = isBookmarks(page) ? new BookmarkScan() : undefined;
      visitStart = Date.now();
      endSince = undefined;
    }
    if (!scan) return;
    scan.add(readWindow(document, postBy));
    const current = scan;
    // The end of the list: it must stay on screen and unchanged for END_STILL_MS, then
    // the scan is sent again as the whole list.
    if (endInView(current)) {
      const key = pageKey(current);
      if (endSince === undefined || key !== endKey) {
        endSince = Date.now();
        endKey = key;
        clearTimeout(endTimer);
        endTimer = setTimeout(() => {
          if (!orphaned() && scan === current && endHeld(current)) sendNow(current);
        }, END_STILL_MS + 50);
      }
    } else {
      endSince = undefined;
      clearTimeout(endTimer);
    }
    clearTimeout(sendTimer);
    sendTimer = setTimeout(() => sendNow(current), SETTLE_MS);
  }, LOOK_MS);
}

function onClick(event: MouseEvent): void {
  if (orphaned()) return stop();
  if (!(event.target instanceof Element)) return;
  const click = bookmarkClick(event.target, postBy);
  if (!click) return;
  applyClick(scan, click);
  send({ type: "bookmark", click });
}

const observer = new MutationObserver(look);
observer.observe(document.body, { childList: true, subtree: true });
document.addEventListener("click", onClick, true);
// Scrolling away from the end (or back to it) is seen even when no row changes.
addEventListener("scroll", look, { passive: true });
look();
