#!/usr/bin/env python3
"""AGENTS.md rule 1 for the Chrome extension: each entry breaks one rule in
Extension/src, runs `bun test`, and reports which tests failed. "SURVIVED" means no
test noticed. Sources are always restored.

  python3 -I scripts/mutation-check-extension.py .
"""
import pathlib, re, subprocess, sys

repo = pathlib.Path(sys.argv[1])
E = "Extension/src/"
M = [
 ("E1 token to impostor", E+"gateway.ts", "if (hello.proof !== undefined && hello.proof === (await hmac(pairing.secret, nonce))) return port;", "if (hello.proof !== undefined) return port;"),
 ("E2 proof ignored", E+"gateway.ts", "if (hello.proof !== undefined && hello.proof === (await hmac(pairing.secret, nonce))) return port;", "return port;"),
 ("E3 revoked as unreachable", E+"gateway.ts", "if (unknownToClew) throw new GatewayError(\"revoked\"", "if (false) throw new GatewayError(\"revoked\""),
 ("E4 last port not first", E+"gateway.ts", "const order = pairing ? [pairing.port, ...PORTS.filter((p) => p !== pairing.port)] : [...PORTS];", "const order = [...PORTS];"),
 ("E5 hmac over nonce+x", E+"gateway.ts", "new TextEncoder().encode(message)", "new TextEncoder().encode(message + \"x\")"),
 ("E6 401 not revoked", E+"gateway.ts", "if (r.status === 401) throw new GatewayError(\"revoked\"", "if (r.status === 999) throw new GatewayError(\"revoked\""),
 ("E7 any playlist", E+"youtube.ts", "u.searchParams.get(\"list\") === \"WL\"", "u.searchParams.has(\"list\")"),
 ("E8 any host", E+"youtube.ts", "u.hostname === \"www.youtube.com\" && ", ""),
 ("E9 lax id", E+"youtube.ts", "const VIDEO_ID = /^[A-Za-z0-9_-]{11}$/;", "const VIDEO_ID = /^[A-Za-z0-9_%-]{10,11}$/;"),
 ("E10 no-videos unread", E+"youtube.ts", "  if (/^no videos?$/i.test(t)) return 0;\n", ""),
 ("E11 views as count", E+"youtube.ts", "/^([\\d,.\\u00a0 ]+) videos?$/i", "/^([\\d,.\\u00a0 ]+) \\w+$/i"),
 ("E12 thousands kept", E+"youtube.ts", "m[1].replace(/[,.\\u00a0 ]/g, \"\")", "m[1].split(\",\")[0]!"),
 ("E13 found = parsed", E+"youtube.ts", "scan: { found: rows.length, parsed:", "scan: { found: entries.length, parsed:"),
 ("E14 total guessed", E+"youtube.ts", "...(total === undefined ? {} : { listTotal: total }),", "listTotal: total ?? entries.length,"),
 ("E15 title attr only", E+"youtube.ts", "(link?.getAttribute(\"title\") || link?.textContent || \"\")", "(link?.getAttribute(\"title\") || \"\")"),
 ("E17 redirects followed", E+"gateway.ts", "{ redirect: \"error\" }", "{ redirect: \"follow\" }"),
 ("E18 progress selector", E+"youtube.ts", "\"ytw-thumbnail-overlay-resume-playback-renderer .ytwThumbnailOverlayResumePlaybackRendererThumbnailOverlayResumePlaybackProgress\"", "\"ytw-thumbnail-overlay-resume-playback-renderer .renamed\""),
 ("E19 progress range", E+"youtube.ts", "pct >= 0 && pct <= 100 ?", "true ?"),
 ("E20 progress as percent", E+"youtube.ts", "Math.round(pct) / 100", "pct"),
 ("E21 progress dropped", E+"youtube.ts", "entries.push(progress === undefined ? { externalRef: id, title } : { externalRef: id, title, progress });", "entries.push({ externalRef: id, title });"),
 ("E22 turned off looks failed", E+"gateway.ts", "    if (r.status === 409) throw new GatewayError(\"turnedOff\", \"list turned off in Clew\", 409);\n", ""),
 ("E23 always at top", E+"x.ts", "atTop: cells.length > 0 && cells[0]?.top === 0", "atTop: true"),
 ("E24 rows unsorted", E+"x.ts", "    .sort((a, b) => (a.top ?? Infinity) - (b.top ?? Infinity));\n", "    ;\n"),
 ("E25 quoted text", E+"x.ts", ".find((t) => !inQuote(post, t))", ".find(() => true)"),
 ("E26 quoted id", E+"x.ts", "if (!link || inQuote(post, link)) continue;", "if (!link) continue;"),
 ("E27 jump unseen", E+"x.ts", "} else if (this.state === \"running\" && !readable.some((p) => this.refs.has(p.externalRef))) {", "} else if (false) {"),
 ("E28 run from anywhere", E+"x.ts", "this.state = window.atTop ? \"running\" : \"broken\";", "this.state = \"running\";"),
 ("E29 unreadable hidden", E+"x.ts", "found: parsed + this.unreadable,", "found: parsed,"),
 ("E30 click inverted", E+"x.ts", "const bookmarked = button.matches(SELECTORS.bookmark);", "const bookmarked = !button.matches(SELECTORS.bookmark);"),
 ("E31 wrong endpoint", E+"gateway.ts", "this.post(pairing, \"/v1/bookmark\", request)", "this.post(pairing, \"/v1/import\", request)"),
 ("E32 bookmark answer lax", E+"contract.ts", "return isObject(v) && isInt(v.listCount) && isImportResult(v.result);", "return isObject(v);"),
 ("E33 zero id", E+"x.ts", "return id && !id.startsWith(\"0\") ? id : undefined;", "return id;"),
 ("E34 article title ignored", E+"x.ts", "const title = articleTitle(post) || postText(post) ||", "const title = postText(post) ||"),
 ("E35 history page missed", E+"x.ts", "(u.pathname === \"/i/history\" || u.pathname === \"/i/bookmarks\")", "u.pathname === \"/i/bookmarks\""),
 ("E36 quoted article", E+"x.ts", "if (!cover || inQuote(post, cover)) return undefined;", "if (!cover) return undefined;"),
 ("E37 author as title", E+"x.ts", "(d) => !d.closest(SELECTORS.userName) && (d.textContent ?? \"\").trim() !== \"\",", "(d) => (d.textContent ?? \"\").trim() !== \"\","),
 ("E38 forget does nothing", E+"x.ts", "    this.entries.splice(i, 1);\n", "    if (i < -1) this.entries.splice(i, 1);\n"),
 ("E39 run not shortened", E+"x.ts", "    if (i < this.run) this.run -= 1;\n", ""),
 ("E40 unbookmarked rows kept", E+"x.ts", "if (post && !isUnbookmarked(post)) posts.push", "if (post) posts.push"),
 ("E41 forgotten stays forgotten", E+"x.ts", "    this.refs.delete(ref);\n", ""),
 ("E42 click forgets nothing", E+"x.ts", "  if (!click.bookmarked) scan?.forget(click.entry.externalRef);", "  void scan; void click;"),
 ("E16 checks lax", E+"contract.ts", "[\"added\", \"renamed\", \"restored\", \"letGo\", \"skipped\", \"progressed\"].every((k) => isInt(r[k]))", "true"),
]
results = []
for name, path, old, new in M:
    f = repo / path
    orig = f.read_text()
    if orig.count(old) != 1:
        results.append((name, f"PATTERN NOT UNIQUE ({orig.count(old)})", [])); continue
    try:
        f.write_text(orig.replace(old, new))
        p = subprocess.run(["bun", "test"], cwd=repo / "Extension", capture_output=True, text=True, timeout=300)
        out = p.stdout + p.stderr
        failed = sorted(set(re.findall(r"\(fail\) (.+?)(?: \[|$)", out, re.M)))
        results.append((name, "KILLED" if failed else "SURVIVED", failed))
    finally:
        f.write_text(orig)
for name, verdict, failed in results:
    print(f"{name:26} {verdict:10} {'; '.join(failed)}")
