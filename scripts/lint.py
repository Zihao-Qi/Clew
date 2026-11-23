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
    """Top-level numbers ("## 7. …") and sub-numbers ("### 4.2 …")."""
    top = set(re.findall(r"^## (\d+)\.", markdown, re.M))
    sub = set(re.findall(r"^### (\d+\.\d+)\b", markdown, re.M))
    return top, sub


def ref_ok(number: str, top: set[str], sub: set[str]) -> bool:
    if "." not in number:
        return number in top
    head = number.split(".")[0]
    if number in sub:
        return True
    # "§1.4" is a numbered item in a section without sub-headings (AGENT §1's list).
    return head in top and not any(s.startswith(head + ".") for s in sub)


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
            for pattern, what in FORBIDDEN:
                if pattern.search(line):
                    found.append(f"{path}:{line_no}: a debug harness uses {what}")
        for m in re.finditer(r"\bAIModel\(", text):
            args = text[m.end() - 1:balanced(text, m.end() - 1)]
            if "memory:" not in args:
                line_no = text.count("\n", 0, m.start()) + 1
                found.append(f"{path}:{line_no}: a debug harness makes an AIModel without its own memory")
    return found


# --- a11y -------------------------------------------------------------------------

def skip_space(text: str, i: int) -> int:
    while i < len(text) and text[i] in " \t\n":
        i += 1
    return i


def check_a11y(files: dict[str, str]) -> list[str]:
    found = []
    for path, text in files.items():
        if not path.startswith("App/Clew/") or not path.endswith(".swift"):
            continue
        for m in re.finditer(r"\bButton\b", text):
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
            # Its modifiers: up to the next blank line, at most 20 lines.
            tail = text[label_end:label_end + 2000].split("\n\n")[0]
            tail = "\n".join(tail.split("\n")[:20])
            if ".accessibilityLabel(" in tail or ".accessibilityHidden(true)" in tail:
                continue
            line_no = text.count("\n", 0, m.start()) + 1
            found.append(f"{path}:{line_no}: an icon-only Button has no .accessibilityLabel")
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
    docs = {"AGENT": "## 1. P\n1. x\n## 7. Memory\n", "ARCHITECTURE": "## 4. Data\n### 4.2 Entities\n## 8. Sync\n"}
    cases = [
        ("docrefs bad", check_docrefs({"a.swift": "// docs/AGENT.md §9"}, docs), 1),
        ("docrefs bad list", check_docrefs({"a.swift": "// AGENT §7, §8"}, docs), 1),
        ("docrefs bad sub", check_docrefs({"a.swift": "// ARCHITECTURE §4.3"}, docs), 1),
        ("docrefs good", check_docrefs({"a.swift": "// AGENT.md §7 and §1.4; ARCHITECTURE §4.2, §8"}, docs), 0),
        ("docrefs range", check_docrefs({"a.swift": "// AGENT §1–9"}, docs), 1),
        ("docrefs date after", check_docrefs({"a.md": "(AGENT §7, 2026-11-22)"}, docs), 0),
        ("harness defaults", check_harness({"App/Clew/XHarness.swift": "let p = UserDefaults.standard"}), 1),
        ("harness ai", check_harness({"App/Clew/XHarness.swift": "let a = AIModel(prefs: p, store: s)"}), 1),
        ("harness app", check_harness({"App/Clew/Snapshot.swift": "let m = AppModel()"}), 1),
        ("harness good", check_harness({"App/Clew/XHarness.swift":
                                        "let a = AIModel(prefs: p, store: s, memory: MemoryBook(url: nil))"}), 0),
        ("harness elsewhere", check_harness({"App/Clew/AppModel.swift": "ai = AIModel()"}), 0),
        ("a11y bad trailing", check_a11y({"App/Clew/V.swift":
            "Button { go() } label: { Image(systemName: \"trash\") }\n    .help(Text(\"Delete\"))\n"}), 1),
        ("a11y bad action", check_a11y({"App/Clew/V.swift":
            "Button(action: close) {\n    Image(systemName: \"xmark\")\n}\n.buttonStyle(.plain)\n"}), 1),
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
