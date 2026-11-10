import { describe, expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { parseHTML } from "linkedom";
import { applyClick, BookmarkScan, bookmarkClick, cellTop, isBookmarks, postId, readPost, readWindow, SELECTOR_VERSION } from "../src/x";

const page = () =>
  parseHTML(readFileSync(new URL("fixtures/x-bookmarks.synthetic.html", import.meta.url), "utf8")).document;
const postBy = (h: string) => `Post by ${h}`;
const e = (n: number) => ({ externalRef: `18500000000000000${String(n).padStart(2, "0")}`, title: `p${n}` });

describe("X bookmarks page", () => {
  test("is the Bookmarks tab (/i/history, or the older /i/bookmarks), never Likes", () => {
    expect(isBookmarks("https://x.com/i/bookmarks")).toBe(true);
    expect(isBookmarks("https://x.com/i/bookmarks?x=1")).toBe(true);
    expect(isBookmarks("https://x.com/i/history")).toBe(true);           // where Bookmarks lives now
    expect(isBookmarks("https://x.com/i/history/likes")).toBe(false);    // the Likes tab
    expect(isBookmarks("https://x.com/home")).toBe(false);
    expect(isBookmarks("https://evil.example/i/bookmarks")).toBe(false);
    expect(isBookmarks("not a url")).toBe(false);
  });

  test("reads rows in list order: own text, not the quoted post's; Post by @name when there is none", () => {
    const w = readWindow(page(), postBy);
    expect(w.atTop).toBe(true);
    expect(w.posts).toEqual([
      { externalRef: "1850000000000000001", title: "Plain text post" },
      { externalRef: "1850000000000000004", title: "Own words" },
      { externalRef: "1850000000000000002", title: "Post by @bob_2" },
      { externalRef: "1850000000000000006", title: "How to learn anything" }, // an X Article: its title
      undefined,                                           // a post it could not read
    ]);
  });

  test("an article's title is never its author's name or a quoted article's", () => {
    const { document } = parseHTML(`
      <article id="bare"><div><div data-testid="User-Name"><div dir="auto"><span>Gus</span></div></div>
        <a href="/gus/status/41"><time></time></a><div><div data-testid="article-cover-image"></div></div></div></article>
      <article id="quoting"><a href="/hal/status/42"><time></time></a>
        <div data-testid="tweetText">My take</div>
        <div role="link"><div><div data-testid="article-cover-image"></div><div dir="auto">Their article</div></div></div></article>`);
    expect(readPost(document.getElementById("bare")!, postBy)?.title).toBe("Post by @gus");
    expect(readPost(document.getElementById("quoting")!, postBy)?.title).toBe("My take");
  });

  test("a page not scrolled to the top is not the top", () => {
    const doc = page();
    doc.querySelector('[data-testid="cellInnerDiv"]')?.setAttribute("style", "transform: translateY(5000px)");
    expect(readWindow(doc, postBy).atTop).toBe(false);
    expect(cellTop(doc.createElement("div"))).toBeUndefined();
  });

  test("ids come from the post's own time link and never start with 0", () => {
    const { document } = parseHTML(`<article><a href="/a/status/0123"><time></time></a></article>
      <article><a href="/a/status/12/photo/1"><time></time></a></article>
      <article><a href="https://evil.example/a/status/77"><time></time></a></article>
      <article><div role="link"><a href="/q/status/5"><time></time></a></div><a href="/a/status/6"><time></time></a></article>`);
    const [zero, photo, other, quoting] = Array.from(document.querySelectorAll("article"));
    expect(postId(quoting!)).toBe("6");                      // not the quoted post's
    expect(postId(zero!)).toBeUndefined();
    expect(postId(photo!)).toBe("12");
    expect(postId(other!)).toBeUndefined();
  });
});

describe("a scan built while scrolling", () => {
  test("rows seen without a break from the top are the run", () => {
    const s = new BookmarkScan();
    s.add({ atTop: true, posts: [e(1), e(2), e(3)] });
    s.add({ atTop: false, posts: [e(3), e(4), e(5)] });        // scrolled: overlaps
    const r = s.request();
    expect(r.fromTop).toBe(5);
    expect(r.entries.map((x) => x.title)).toEqual(["p1", "p2", "p3", "p4", "p5"]);
    expect(r.scan).toEqual({ found: 5, parsed: 5, selectorVersion: SELECTOR_VERSION });
    expect(r.source).toBe("extension.x");
  });

  test("a jump past some rows ends the run; later rows are still added", () => {
    const s = new BookmarkScan();
    s.add({ atTop: true, posts: [e(1), e(2)] });
    s.add({ atTop: false, posts: [e(7), e(8)] });              // nothing in common
    s.add({ atTop: false, posts: [e(8), e(9)] });
    const r = s.request();
    expect(r.fromTop).toBe(2);
    expect(r.entries.length).toBe(5);
  });

  test("a scan that did not start at the top has no run", () => {
    const s = new BookmarkScan();
    s.add({ atTop: false, posts: [] });                        // nothing loaded yet: still waiting
    s.add({ atTop: false, posts: [e(4), e(5)] });
    s.add({ atTop: true, posts: [e(1), e(2)] });
    expect(s.request().fromTop).toBe(0);
  });

  test("a post unbookmarked during the visit leaves the scan and the run", () => {
    const s = new BookmarkScan();
    s.add({ atTop: true, posts: [e(1), e(2), e(3)] });
    s.forget(e(2).externalRef);
    s.forget("unknown");
    expect(s.request().entries.map((x) => x.title)).toEqual(["p1", "p3"]);
    expect(s.request().fromTop).toBe(2);
    s.add({ atTop: false, posts: [e(3), e(5)] });              // still unbroken
    expect(s.request().fromTop).toBe(3);
  });

  test("an unbookmark click forgets the post; a bookmark click does not; bookmarked again, it is back", () => {
    const s = new BookmarkScan();
    s.add({ atTop: true, posts: [e(1), e(2), e(3)] });
    applyClick(s, { source: "extension.x", entry: { externalRef: e(1).externalRef, title: "" }, bookmarked: true });
    expect(s.request().entries.length).toBe(3);
    applyClick(s, { source: "extension.x", entry: { externalRef: e(2).externalRef, title: "" }, bookmarked: false });
    expect(s.request().entries.map((x) => x.title)).toEqual(["p1", "p3"]);
    applyClick(undefined, { source: "extension.x", entry: e(3), bookmarked: false });   // not on Bookmarks: fine
    s.add({ atTop: false, posts: [e(1), e(2), e(3)] });        // bookmarked again in the same visit
    expect(s.request().entries.map((x) => x.title)).toContain("p2");
  });

  test("forgetting a post seen after a break leaves the run as it was", () => {
    const s = new BookmarkScan();
    s.add({ atTop: true, posts: [e(1), e(2)] });
    s.add({ atTop: false, posts: [e(7), e(8)] });              // a break
    s.forget(e(8).externalRef);
    expect(s.request().fromTop).toBe(2);
    expect(s.request().entries.length).toBe(3);
  });

  test("a post showing the Bookmark button is not on the list", () => {
    const doc = page();
    const first = doc.querySelector('[data-testid="removeBookmark"]')!;
    first.setAttribute("data-testid", "bookmark");                // X flipped it after the click
    const w = readWindow(doc, postBy);
    expect(w.posts.map((p) => p?.externalRef)).not.toContain("1850000000000000001");
    expect(w.posts.filter((p) => p === undefined).length).toBe(1);   // not counted as unreadable
  });

  test("an unreadable row is reported, so Clew compares nothing", () => {
    const s = new BookmarkScan();
    s.add({ atTop: true, posts: [e(1), undefined, e(3)] });
    expect(s.request().scan.found).toBe(3);
    expect(s.request().scan.parsed).toBe(2);
  });
});

describe("the bookmark button", () => {
  test("bookmarking a post anywhere on x.com sends it", () => {
    const doc = page();
    const icon = doc.getElementById("icon")!;
    expect(bookmarkClick(icon, postBy)).toEqual({
      source: "extension.x",
      entry: { externalRef: "1850000000000000005", title: "A post in the home timeline" },
      bookmarked: true,
    });
  });

  test("removing a bookmark sends it as removed", () => {
    const doc = page();
    const button = doc.querySelector('[data-testid="removeBookmark"]')!;
    expect(bookmarkClick(button, postBy)?.bookmarked).toBe(false);
    expect(bookmarkClick(button, postBy)?.entry.externalRef).toBe("1850000000000000001");
  });

  test("other clicks, and buttons outside a post, send nothing", () => {
    const doc = page();
    expect(bookmarkClick(doc.querySelector('[data-testid="tweetText"]')!, postBy)).toBeUndefined();
    const { document } = parseHTML(`<button data-testid="bookmark">Bookmark</button>`);
    expect(bookmarkClick(document.querySelector("button")!, postBy)).toBeUndefined();
  });
});
