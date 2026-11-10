// Runs on x.com. Two jobs, both light:
// - On the Bookmarks page, it reads the rows as you scroll (X keeps only the rows near
//   the screen) and sends the scan once the page settles.
// - Anywhere on x.com, a click on a post's bookmark button is sent at once: one click
//   listener, idle until you click.

import { BookmarkScan, bookmarkClick, isBookmarks, readWindow } from "./x";

const SETTLE_MS = 1500;
const LOOK_MS = 250;
const postBy = (handle: string) => chrome.i18n.getMessage("postBy", [handle]) || `Post by ${handle}`;

let scan: BookmarkScan | undefined;
let page = "";
let lookTimer: ReturnType<typeof setTimeout> | undefined;
let sendTimer: ReturnType<typeof setTimeout> | undefined;

/** After the extension is reloaded, this copy in an open tab is cut off; it goes quiet. */
function orphaned(): boolean {
  return !chrome.runtime?.id;
}

function stop(): void {
  clearTimeout(lookTimer);
  clearTimeout(sendTimer);
  observer.disconnect();
  document.removeEventListener("click", onClick, true);
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
    }
    if (!scan) return;
    scan.add(readWindow(document, postBy));
    clearTimeout(sendTimer);
    const current = scan;
    sendTimer = setTimeout(() => send({ type: "xBookmarks", scan: current.request() }), SETTLE_MS);
  }, LOOK_MS);
}

function onClick(event: MouseEvent): void {
  if (orphaned()) return stop();
  if (!(event.target instanceof Element)) return;
  const click = bookmarkClick(event.target, postBy);
  if (!click) return;
  if (!click.bookmarked) scan?.forget(click.entry.externalRef);
  send({ type: "bookmark", click });
}

const observer = new MutationObserver(look);
observer.observe(document.body, { childList: true, subtree: true });
document.addEventListener("click", onClick, true);
look();
