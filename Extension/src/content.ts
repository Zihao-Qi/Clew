// Runs on youtube.com. YouTube is a single-page app, so it watches navigation and
// scans only on the Watch Later page, again as more rows load while scrolling.

import { isWatchLater, scanWatchLater } from "./youtube";

const SETTLE_MS = 1500;
let timer: ReturnType<typeof setTimeout> | undefined;
let observer: MutationObserver | undefined;

function scanSoon(): void {
  clearTimeout(timer);
  timer = setTimeout(() => {
    if (!isWatchLater(location.href)) return;
    chrome.runtime.sendMessage({ type: "watchLater", scan: scanWatchLater(document) }).catch(() => {});
  }, SETTLE_MS);
}

function onPage(): void {
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
