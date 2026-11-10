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
 ("E16 checks lax", E+"contract.ts", "[\"added\", \"renamed\", \"restored\", \"letGo\", \"skipped\"].every((k) => isInt(r[k]))", "true"),
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
