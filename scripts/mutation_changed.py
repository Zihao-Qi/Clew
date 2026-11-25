"""Which mutation entries touch what this branch changed (`--changed` in both mutation
scripts). An entry is picked when the lines its pattern covers overlap a line changed
since the branch left main (committed, staged, unstaged or untracked), when its pattern
is not found exactly once, or when its file is gone: those are never skipped silently.
A check you weakened or rewrote: name its entries with --only (AGENTS.md)."""
import pathlib
import re
import subprocess


def _git(repo: pathlib.Path, *args: str) -> str:
    result = subprocess.run(["git", *args], cwd=repo, capture_output=True, text=True)
    if result.returncode != 0:
        raise SystemExit(f"FAIL: git {' '.join(args)}: {result.stderr.strip()}")
    return result.stdout


def changed_lines(repo: pathlib.Path) -> dict[str, set[int] | None]:
    """New-side line numbers changed since the merge base with main, per file (None: the
    whole file, as for an untracked one)."""
    base = _git(repo, "merge-base", "main", "HEAD").strip()
    # Fixed prefixes, so diff.noprefix or diff.mnemonicPrefix in someone's config cannot
    # hide the paths; no external diff tool.
    diff = _git(repo, "diff", "-U0", "--no-ext-diff", "--no-color", "--src-prefix=a/", "--dst-prefix=b/", base)
    lines: dict[str, set[int] | None] = {}
    path, header = None, False
    for line in diff.splitlines():
        if line.startswith("diff --git "):
            path, header = None, True          # a file's header: until its first hunk
        elif header and line.startswith("+++ "):
            path = line[6:] if line.startswith("+++ b/") else None   # /dev/null: deleted
        elif line.startswith("@@"):
            header = False
            m = re.match(r"@@ -\d+(?:,\d+)? \+(\d+)(?:,(\d+))? @@", line)
            if path and m:
                start, count = int(m.group(1)), int(m.group(2) or "1")
                found = lines.setdefault(path, set())
                if found is not None:
                    found.update(range(start, start + max(count, 1)))
    for path in _git(repo, "ls-files", "--others", "--exclude-standard").splitlines():
        lines[path] = None                     # untracked: every line is new
    return lines


def touches(repo: pathlib.Path, path: str, old: str, changed: dict[str, set[int] | None]) -> bool:
    """True if the entry must run: its pattern's lines overlap a changed line, its file is
    gone, or its pattern is not found exactly once (then the run reports it)."""
    file = repo / path
    if not file.exists():
        return True
    text = file.read_text()
    if text.count(old) != 1:
        return True
    if path not in changed:
        return False
    if changed[path] is None:
        return True
    first = text.count("\n", 0, text.find(old)) + 1
    last = first + old.count("\n")
    return any(n in changed[path] for n in range(first, last + 1))
