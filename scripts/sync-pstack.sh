#!/usr/bin/env bash
# The only supported way to replace the vendored pstack snapshot.
set -euo pipefail

if [[ $# -ne 1 || "$1" == "-h" || "$1" == "--help" ]]; then
  echo "usage: scripts/sync-pstack.sh <source-dir>" >&2
  exit 2
fi

src=$(cd "$1" && pwd)
if [[ ! -f "$src/PSTACK_VERSION" ]]; then
  echo "sync-pstack: $src has no PSTACK_VERSION" >&2
  exit 1
fi

root=$(git rev-parse --show-toplevel)
dest="$root/.cursor/skills/pstack"
mkdir -p "$dest"

python3 - "$src" "$dest" <<'PY'
import hashlib
import os
import sys
from pathlib import Path

src = Path(sys.argv[1])
dest = Path(sys.argv[2])


def file_list(root: Path) -> list[str]:
    found: list[str] = []
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames.sort()
        for name in sorted(filenames):
            if name == "CHECKSUMS":
                continue
            path = Path(dirpath) / name
            if path.is_symlink():
                raise SystemExit(f"sync-pstack: refusing symlink {path}")
            found.append(path.relative_to(root).as_posix())
    return found


wanted = set(file_list(src))
for dirpath, dirnames, filenames in os.walk(dest):
    for name in filenames:
        path = Path(dirpath) / name
        rel = path.relative_to(dest).as_posix()
        if rel != "CHECKSUMS" and rel not in wanted:
            path.unlink()

for rel in sorted(wanted):
    target = dest / rel
    target.parent.mkdir(parents=True, exist_ok=True)
    data = (src / rel).read_bytes()
    if not target.exists() or target.read_bytes() != data:
        target.write_bytes(data)

for dirpath, dirnames, filenames in os.walk(dest, topdown=False):
    directory = Path(dirpath)
    if directory != dest and not any(directory.iterdir()):
        directory.rmdir()

lines = []
for rel in sorted(wanted):
    digest = hashlib.sha256((dest / rel).read_bytes()).hexdigest()
    lines.append(f"{digest}  {rel}")
text = "\n".join(lines) + "\n"
checksums = dest / "CHECKSUMS"
if not checksums.exists() or checksums.read_text() != text:
    checksums.write_text(text)
PY

tr -d '[:space:]' < "$dest/PSTACK_VERSION"
echo
