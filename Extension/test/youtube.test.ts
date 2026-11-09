import { describe, expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { parseHTML } from "linkedom";
import { isWatchLater, parseCount, scanWatchLater, SELECTOR_VERSION, videoId } from "../src/youtube";

const page = (name: string) => parseHTML(readFileSync(new URL(`fixtures/${name}`, import.meta.url), "utf8")).document;

describe("Watch Later scan", () => {
  test("reads every row and the list's own count", () => {
    const scan = scanWatchLater(page("watch-later.synthetic.html"));
    expect(scan).toEqual({
      source: "extension.youtube",
      listTotal: 3,
      entries: [
        { externalRef: "aaaaaaaaaaa", title: "First video" },
        { externalRef: "bbbbbbbbbbb", title: "Second video" },
        { externalRef: "ccccccccccc", title: "Third video" },
      ],
      scan: { found: 3, parsed: 3, selectorVersion: SELECTOR_VERSION },
    });
  });

  test("a changed page is reported, not silently empty", () => {
    // YouTube renamed the title link: rows are found, none can be read.
    const doc = page("watch-later.synthetic.html");
    for (const a of Array.from(doc.querySelectorAll("a#video-title"))) a.setAttribute("id", "renamed");
    const scan = scanWatchLater(doc);
    expect(scan.entries).toEqual([]);
    expect(scan.scan).toMatchObject({ found: 3, parsed: 0 });
    expect(scan.listTotal).toBe(3);
  });

  test("no readable count means no listTotal (so Clew never removes anything)", () => {
    const doc = page("watch-later.synthetic.html");
    for (const el of Array.from(doc.querySelectorAll("yt-formatted-string"))) el.textContent = "3 vidéos";
    expect("listTotal" in scanWatchLater(doc)).toBe(false);
  });

  test("rows without a usable id are counted as unread", () => {
    const doc = page("watch-later.synthetic.html");
    doc.querySelector("a#video-title")?.setAttribute("href", "/shorts/aaaaaaaaaaa");
    expect(scanWatchLater(doc).scan).toMatchObject({ found: 3, parsed: 2 });
  });
});

describe("helpers", () => {
  test("only the Watch Later page", () => {
    expect(isWatchLater("https://www.youtube.com/playlist?list=WL")).toBe(true);
    expect(isWatchLater("https://www.youtube.com/playlist?list=PL123")).toBe(false);
    expect(isWatchLater("https://www.youtube.com/watch?v=aaaaaaaaaaa&list=WL")).toBe(false);
    expect(isWatchLater("https://evil.example/playlist?list=WL")).toBe(false);
  });

  test("video ids are exactly 11 safe characters", () => {
    expect(videoId("/watch?v=aaaaaaaaaaa&list=WL")).toBe("aaaaaaaaaaa");
    expect(videoId("/watch?v=aaaaaaaaaa")).toBeUndefined();
    expect(videoId("/watch?v=aaaaaaaaaa%2F")).toBeUndefined();
    expect(videoId(null)).toBeUndefined();
  });

  test("counts", () => {
    expect(parseCount("12 videos")).toBe(12);
    expect(parseCount(" 1,234\n videos ")).toBe(1234);
    expect(parseCount("1 video")).toBe(1);
    expect(parseCount("No videos")).toBe(0);
    expect(parseCount("12 views")).toBeUndefined();
    expect(parseCount("Updated today")).toBeUndefined();
  });
});
