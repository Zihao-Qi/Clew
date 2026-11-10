// Runs on youtube.com. YouTube is a single-page app, so it watches navigation and
// scans only on the Watch Later page, again as more rows load while scrolling.

import { isWatchLater, scanWatchLater } from "./youtube";

const SETTLE_MS = 1500;
let timer: ReturnType<typeof setTimeout> | undefined;
let observer: MutationObserver | undefined;

/** After the extension is reloaded or updated, this copy in an already-open tab is
 * cut off from it (no `chrome.runtime.id`); it goes quiet instead of throwing
 * "Extension context invalidated". The new copy runs when the tab reloads. */
function orphaned(): boolean {
  return !chrome.runtime?.id;
}

function stop(): void {
  clearTimeout(timer);
  observer?.disconnect();
  observer = undefined;
  document.removeEventListener("yt-navigate-finish", onPage);
}

function scanSoon(): void {
  clearTimeout(timer);
  timer = setTimeout(() => {
    if (orphaned()) return stop();
    if (!isWatchLater(location.href)) return;
    try {
      chrome.runtime.sendMessage({ type: "watchLater", scan: scanWatchLater(document) }).catch(() => {});
    } catch {
      stop();
    }
  }, SETTLE_MS);
}

function onPage(): void {
  if (orphaned()) return stop();
  observer?.disconnect();
  observer = undefined;
  if (!isWatchLater(location.href)) return;
  scanSoon();
  // Rows arrive in batches of 100 as the page scrolls; rescan once they settle.
  observer = new MutationObserver(scanSoon);
  observer.observe(document.body, { childList: true, subtree: true });
}

document.addEventListener("yt-navigate-finish", onPage);
onPage();
