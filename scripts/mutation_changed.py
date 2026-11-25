"""Which mutation entries touch what this branch changed (`--changed` in both mutation
scripts): an entry is picked when the lines its pattern covers overlap a line changed
since the branch left main (committed or not). The full list still runs when shared code
moves or a check is weakened: then name the entries with --only (AGENTS.md)."""
import pathlib
import re
import subprocess


def changed_lines(repo: pathlib.Path) -> dict[str, set[int]]:
    """New-side line numbers changed since the merge base with main, per file."""
    base = subprocess.run(["git", "merge-base", "main", "HEAD"], cwd=repo, capture_output=True, text=True).stdout.strip()
    diff = subprocess.run(["git", "diff", "-U0", base or "main"], cwd=repo, capture_output=True, text=True).stdout
    lines: dict[str, set[int]] = {}
    path = None
    for line in diff.splitlines():
        if line.startswith("+++ "):
            path = line[6:] if line.startswith("+++ b/") else None
        elif path and line.startswith("@@"):
            m = re.match(r"@@ -\d+(?:,\d+)? \+(\d+)(?:,(\d+))? @@", line)
            if m:
                start, count = int(m.group(1)), int(m.group(2) or "1")
                lines.setdefault(path, set()).update(range(start, start + max(count, 1)))
    return lines


def touches(repo: pathlib.Path, path: str, old: str, changed: dict[str, set[int]]) -> bool:
    """True if the pattern's lines in `path` overlap a changed line."""
    if path not in changed:
        return False
    text = (repo / path).read_text()
    at = text.find(old)
    if at < 0:
        return True   # moved or gone: --patterns reports it; run it so it is seen
    first = text.count("\n", 0, at) + 1
    last = first + old.count("\n")
    return any(n in changed[path] for n in range(first, last + 1))
