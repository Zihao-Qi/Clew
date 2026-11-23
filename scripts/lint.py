#!/usr/bin/env python3
"""Repo lint for mistakes that kept coming back (2026-11-22 review of past errors).

  python3 -I scripts/lint.py .              # lint the repo; exit 1 on any finding
  python3 -I scripts/lint.py . --self-test  # each check must catch its bad samples

Checks:
  docrefs  "AGENT.md §7" / "ARCHITECTURE §4.2" in code and docs name a real section
           (they went stale when AGENT.md was renumbered).
  harness  the debug harnesses never touch this Mac's real data: no
           UserDefaults.standard, no real memory file or Keychain, no live AppModel()
           or AIModel() (an AI check once wrote to the real memory file).
  a11y     every icon-only Button in App/Clew has an .accessibilityLabel (AGENTS.md
           rule 8; new icon buttons kept arriving without one). A deliberate exception
           carries `// lint: no-label <reason>` on the Button's line.
"""
import pathlib
import re
import sys

# --- docrefs ----------------------------------------------------------------------

DOCS = {"AGENT": "docs/AGENT.md", "ARCHITECTURE": "docs/ARCHITECTURE.md"}
REF = re.compile(r"\b(AGENT|ARCHITECTURE)(?:\.md)? (§\d+(?:\.\d+)?(?:\s*(?:,|/|and|or)\s*§\d+(?:\.\d+)?|\s*[–-]\s*§?\d+(?:\.\d+)?(?![\d-]))*)")


def sections(markdown: str) -> tuple[set[str], set[str]]:
    """Top-level numbers ("## 7. …") and sub-numbers: "### 4.2 …" headings, or "1.4" for
    the numbered list items ("4. …") of a section without sub-headings."""
    top = set(re.findall(r"^## (\d+)\.", markdown, re.M))
    sub = set(re.findall(r"^### (\d+\.\d+)\b", markdown, re.M))
    parts = re.split(r"^## (\d+)\.", markdown, flags=re.M)
    for n, body in zip(parts[1::2], parts[2::2]):
        if not any(x.startswith(n + ".") for x in sub):
            sub |= {f"{n}.{i}" for i in re.findall(r"^(\d+)\. ", body, re.M)}
    return top, sub


def ref_ok(number: str, top: set[str], sub: set[str]) -> bool:
    if "." not in number:
        return number in top
    return number in sub


def check_docrefs(files: dict[str, str], docs: dict[str, str]) -> list[str]:
    known = {name: sections(text) for name, text in docs.items()}
    found = []
    for path, text in files.items():
        for line_no, line in enumerate(text.splitlines(), 1):
            for m in REF.finditer(line):
                top, sub = known[m.group(1)]
                for number in re.findall(r"\d+(?:\.\d+)?", m.group(2)):
                    if not ref_ok(number, top, sub):
                        found.append(f"{path}:{line_no}: {m.group(1)} §{number} is not a section of {DOCS[m.group(1)]}")
    return found


def code(line: str) -> str:
    """The line without its `//` comment (not the `//` of "https://" in a string)."""
    return re.sub(r"(?<![:/\\])//.*$", "", line)


# --- harness ----------------------------------------------------------------------

FORBIDDEN = [
    (re.compile(r"UserDefaults\.standard"), "UserDefaults.standard (use a suite of its own)"),
    (re.compile(r"MemoryBook\.defaultURL"), "the real memory file"),
    (re.compile(r"\bKeychainSession\("), "the real Keychain"),
    (re.compile(r"\bAppModel\(\s*\)"), "the live AppModel()"),
]


def balanced(text: str, start: int, open_: str = "(", close: str = ")") -> int:
    """Index just after the bracket that closes the one at `start`."""
    depth = 0
    for i in range(start, len(text)):
        if text[i] == open_:
            depth += 1
        elif text[i] == close:
            depth -= 1
            if depth == 0:
                return i + 1
    return len(text)


def check_harness(files: dict[str, str]) -> list[str]:
    found = []
    for path, text in files.items():
        name = pathlib.Path(path).name
        if "Harness" not in name and name != "Snapshot.swift":
            continue
        for line_no, line in enumerate(text.splitlines(), 1):
            if line.lstrip().startswith("//"):
                continue
            for pattern, what in FORBIDDEN:
                if pattern.search(line):
                    found.append(f"{path}:{line_no}: a debug harness uses {what}")
        uncommented = "\n".join(code(l) for l in text.splitlines())
        for m in re.finditer(r"\bAIModel\(", uncommented):
            args = uncommented[m.end() - 1:balanced(uncommented, m.end() - 1)]
            missing = [k for k in ("prefs:", "store:", "transport:", "memory:") if k not in args]
            if missing:
                line_no = uncommented.count("\n", 0, m.start()) + 1
                found.append(f"{path}:{line_no}: a debug harness makes an AIModel with the real {', '.join(missing)}")
    return found


# --- a11y -------------------------------------------------------------------------

def skip_space(text: str, i: int) -> int:
    while i < len(text) and text[i] in " \t\n":
        i += 1
    return i


def modifier_chain(text: str, start: int) -> str:
    """The control's own modifiers after its closing brace: lines starting with "."
    (with their multi-line arguments), stopping at the first line that is not one."""
    def delta(line: str) -> int:
        return line.count("(") + line.count("{") - line.count(")") - line.count("}")
    end = text.find("\n", start)
    first = code(text[start:end if end >= 0 else len(text)])
    # The container may close on this line: what follows it there and after is its own.
    depth = 0
    for k, ch in enumerate(first):
        depth += {"(": 1, "{": 1, ")": -1, "}": -1}.get(ch, 0)
        if depth < 0:
            return first[:k]
    chain = [first]
    i = end + 1 if end >= 0 else len(text)
    while i < len(text):
        nl = text.find("\n", i)
        line = code(text[i:nl if nl >= 0 else len(text)])
        if line.strip() == "" and text[i:nl if nl >= 0 else len(text)].strip().startswith("//"):
            i = nl + 1 if nl >= 0 else len(text)
            continue   # a comment line between modifiers
        if depth <= 0 and not line.lstrip().startswith("."):
            break
        depth += delta(line)
        if depth < 0:
            break
        chain.append(line)
        if nl < 0:
            break
        i = nl + 1
    return "\n".join(chain)


def check_a11y(files: dict[str, str]) -> list[str]:
    found = []
    for path, text in files.items():
        if not path.startswith("App/Clew/") or not path.endswith(".swift"):
            continue
        for m in re.finditer(r"\b(Button|Menu)\b", text):
            line_start = text.rfind("\n", 0, m.start()) + 1
            line_end = text.find("\n", m.start())
            line = text[line_start:line_end]
            if "lint: no-label" in line or line.lstrip().startswith(("//", "///")):
                continue
            i = skip_space(text, m.end())
            args = ""
            if i < len(text) and text[i] == "(":
                end = balanced(text, i)
                args = text[i:end]
                i = skip_space(text, end)
            # A title in the arguments ("Done", Text(...), a variable) is a text button.
            if args and "action:" not in args.split(",")[0] and args.strip("() \n") != "":
                if not args.lstrip("(").lstrip().startswith(("role:", "action:")):
                    continue
            if i >= len(text) or text[i] != "{":
                continue
            first_end = balanced(text, i, "{", "}")
            label_start, label_end = i, first_end
            j = skip_space(text, first_end)
            if text.startswith("label:", j):
                k = skip_space(text, j + len("label:"))
                if k < len(text) and text[k] == "{":
                    label_start, label_end = k, balanced(text, k, "{", "}")
            elif "action:" not in args and args.strip("() \n") == "":
                # Button { action } with no label closure: not a button we can judge.
                continue
            label = text[label_start:label_end]
            if "Image(" not in label or re.search(r"\b(Text|Label)\s*[({]", label):
                continue
            # Only its own modifier chain counts, never a sibling's (review); a label on
            # the image inside counts too.
            chain = modifier_chain(text, label_end)
            if any(k in chain or k in label for k in (".accessibilityLabel(", ".accessibilityHidden(true)")):
                continue
            line_no = text.count("\n", 0, m.start()) + 1
            found.append(f"{path}:{line_no}: an icon-only {m.group(1)} has no .accessibilityLabel")
    return found


# --- running ----------------------------------------------------------------------

def repo_files(root: pathlib.Path) -> dict[str, str]:
    files = {}
    for pattern in ["Sources/**/*.swift", "App/**/*.swift", "Tests/**/*.swift", "docs/*.md", "SPEC.md", "AGENTS.md"]:
        for p in root.glob(pattern):
            files[str(p.relative_to(root))] = p.read_text(encoding="utf-8")
    return files


def lint(root: pathlib.Path) -> list[str]:
    files = repo_files(root)
    docs = {name: (root / path).read_text(encoding="utf-8") for name, path in DOCS.items()}
    return check_docrefs(files, docs) + check_harness(files) + check_a11y(files)


def self_test() -> int:
    """Each check must flag its bad samples and pass its good ones."""
    docs = {"AGENT": "## 1. P\n1. a\n2. b\n3. c\n4. d\n## 7. Memory\n", "ARCHITECTURE": "## 4. Data\n### 4.2 Entities\n## 8. Sync\n"}
    cases = [
        ("docrefs bad", check_docrefs({"a.swift": "// docs/AGENT.md §9"}, docs), 1),
        ("docrefs bad list", check_docrefs({"a.swift": "// AGENT §7, §8"}, docs), 1),
        ("docrefs bad sub", check_docrefs({"a.swift": "// ARCHITECTURE §4.3"}, docs), 1),
        ("docrefs good", check_docrefs({"a.swift": "// AGENT.md §7 and §1.4; ARCHITECTURE §4.2, §8"}, docs), 0),
        ("docrefs range", check_docrefs({"a.swift": "// AGENT §1–9"}, docs), 1),
        ("docrefs date after", check_docrefs({"a.md": "(AGENT §7, 2026-11-22)"}, docs), 0),
        ("docrefs no such item", check_docrefs({"a.swift": "// AGENT §1.9"}, docs), 1),
        ("harness defaults", check_harness({"App/Clew/XHarness.swift": "let p = UserDefaults.standard"}), 1),
        ("harness ai", check_harness({"App/Clew/XHarness.swift": "let a = AIModel(prefs: p, store: s)"}), 1),
        ("harness app", check_harness({"App/Clew/Snapshot.swift": "let m = AppModel()"}), 1),
        ("harness ai only memory", check_harness({"App/Clew/XHarness.swift":
                                        "let a = AIModel(memory: MemoryBook(url: nil))"}), 1),
        ("harness good", check_harness({"App/Clew/XHarness.swift":
            "let a = AIModel(prefs: p, store: s,\n  transport: t, memory: MemoryBook(url: nil))"}), 0),
        ("harness comment", check_harness({"App/Clew/XHarness.swift": "// never UserDefaults.standard here"}), 0),
        ("harness ai comment", check_harness({"App/Clew/XHarness.swift": "// never AIModel() here\nlet x = 1"}), 0),
        ("harness elsewhere", check_harness({"App/Clew/AppModel.swift": "ai = AIModel()"}), 0),
        ("a11y bad trailing", check_a11y({"App/Clew/V.swift":
            "Button { go() } label: { Image(systemName: \"trash\") }\n    .help(Text(\"Delete\"))\n"}), 1),
        ("a11y bad action", check_a11y({"App/Clew/V.swift":
            "Button(action: close) {\n    Image(systemName: \"xmark\")\n}\n.buttonStyle(.plain)\n"}), 1),
        ("a11y sibling's label", check_a11y({"App/Clew/V.swift":
            "Button { a() } label: { Image(systemName: \"x\") }\n.buttonStyle(.plain)\n"
            "Button { b() } label: { Image(systemName: \"y\") }\n.accessibilityLabel(Text(\"B\"))\n"}), 1),
        ("a11y in ForEach", check_a11y({"App/Clew/V.swift":
            "ForEach(xs) { x in\n    Button { add(x) } label: { Image(systemName: \"plus\") }\n        .help(Text(\"Add\"))\n}\n"
            ".accessibilityLabel(Text(\"List\"))\n"}), 1),
        ("a11y menu icon", check_a11y({"App/Clew/V.swift":
            "Menu {\n    Button(\"A\") { a() }\n} label: { Image(systemName: \"ellipsis\") }\n"}), 1),
        ("a11y label inside", check_a11y({"App/Clew/V.swift":
            "Button { go() } label: { Image(systemName: \"x\").accessibilityLabel(\"Close\") }\n"}), 0),
        ("a11y container's label", check_a11y({"App/Clew/V.swift":
            "HStack { Button { a() } label: { Image(systemName: \"x\") } }\n.accessibilityLabel(Text(\"Row\"))\n"}), 1),
        ("a11y commented label", check_a11y({"App/Clew/V.swift":
            "Button { a() } label: { Image(systemName: \"x\") }\n    // .accessibilityLabel(Text(\"X\"))\n"
            "    .buttonStyle(.plain)\n"}), 1),
        ("a11y label in a same-line comment", check_a11y({"App/Clew/V.swift":
            "Button { a() } label: { Image(systemName: \"x\") } // .accessibilityLabel(Text(\"X\"))\n"}), 1),
        ("a11y url in chain", check_a11y({"App/Clew/V.swift":
            "Button { a() } label: { Image(systemName: \"x\") }\n"
            "    .help(Text(\"https://x\")).accessibilityLabel(Text(\"X\"))\n"}), 0),
        ("a11y container's multiline label", check_a11y({"App/Clew/V.swift":
            "HStack { Button { a() } label: { Image(systemName: \"x\") } }\n.accessibilityLabel(\n  Text(\"Row\")\n)\n"}), 1),
        ("a11y container's same-line label", check_a11y({"App/Clew/V.swift":
            "HStack { Button { a() } label: { Image(systemName: \"x\") } }.accessibilityLabel(Text(\"Row\"))\n"}), 1),
        ("a11y container closes after a modifier", check_a11y({"App/Clew/V.swift":
            "HStack { Button { a() } label: { Image(systemName: \"x\") }\n    .buttonStyle(.plain) }\n"
            ".accessibilityLabel(Text(\"Row\"))\n"}), 1),
        ("a11y bracket in a comment", check_a11y({"App/Clew/V.swift":
            "Button { a() } label: { Image(systemName: \"x\") }\n    .buttonStyle(.plain) // (\n"
            "Button { b() } label: { Image(systemName: \"y\") }\n.accessibilityLabel(Text(\"B\"))\n"}), 1),
        ("a11y multiline modifier", check_a11y({"App/Clew/V.swift":
            "Button { go() } label: { Image(systemName: \"x\") }\n    .help(Text(\n  \"Close\"))\n    .accessibilityLabel(Text(\"Close\"))\n"}), 0),
        ("a11y comment in chain", check_a11y({"App/Clew/V.swift":
            "Button { go() } label: { Image(systemName: \"x\") }\n    .buttonStyle(.plain)\n    // why\n"
            "    .accessibilityLabel(Text(\"Close\"))\n"}), 0),
        ("a11y good", check_a11y({"App/Clew/V.swift":
            "Button { go() } label: { Image(systemName: \"trash\") }\n    .accessibilityLabel(Text(\"Delete\"))\n"}), 0),
        ("a11y text button", check_a11y({"App/Clew/V.swift": "Button(\"Done\") { done() }\n"}), 0),
        ("a11y label closure", check_a11y({"App/Clew/V.swift":
            "Button { go() } label: {\n    Label { t } icon: { Image(systemName: i) }\n}\n"}), 0),
        ("a11y label button", check_a11y({"App/Clew/V.swift":
            "Button { add() } label: { Label(\"Add\", systemImage: \"plus\") }\n"}), 0),
        ("a11y exception", check_a11y({"App/Clew/V.swift":
            "Button { go() } label: { Image(systemName: \"x\") } // lint: no-label decorative\n"}), 0),
    ]
    failed = 0
    for name, found, expected in cases:
        ok = len(found) == expected
        failed += 0 if ok else 1
        print(("PASS" if ok else "FAIL"), name, "" if ok else f"(expected {expected}, got {found})")
    return 1 if failed else 0


if __name__ == "__main__":
    root = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else ".")
    if "--self-test" in sys.argv:
        sys.exit(self_test())
    findings = lint(root)
    for f in findings:
        print(f)
    print(f"{len(findings)} finding(s)")
    sys.exit(1 if findings else 0)
