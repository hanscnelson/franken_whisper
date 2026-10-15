#!/usr/bin/env bash
# Fail unless the always-on pstack rule and the vendored snapshot are intact.
set -euo pipefail

root=$(git rev-parse --show-toplevel)
rule="$root/.cursor/rules/pstack.mdc"
dir="$root/.cursor/skills/pstack"

if [[ ! -f "$rule" ]]; then
  echo "pstack-present: missing .cursor/rules/pstack.mdc. Rule: Cloud agents get pstack automatically." >&2
  exit 1
fi

python3 - "$rule" "$dir" <<'PY'
import hashlib
import os
import sys
from pathlib import Path

rule = Path(sys.argv[1])
root = Path(sys.argv[2])
text = rule.read_text()
if not text.startswith("---"):
    raise SystemExit(
        "pstack-present: .cursor/rules/pstack.mdc has no YAML frontmatter. "
        "Rule: Cloud agents get pstack automatically."
    )
parts = text.split("---", 2)
if len(parts) < 3:
    raise SystemExit(
        "pstack-present: .cursor/rules/pstack.mdc frontmatter is unclosed. "
        "Rule: Cloud agents get pstack automatically."
    )
front_lines = [line.strip() for line in parts[1].splitlines()]
if "alwaysApply: true" not in front_lines:
    raise SystemExit(
        "pstack-present: .cursor/rules/pstack.mdc lacks alwaysApply: true. "
        "Rule: Cloud agents get pstack automatically."
    )

if not root.is_dir():
    raise SystemExit(
        "pstack-present: missing .cursor/skills/pstack/. "
        "Rule: Cloud agents get pstack automatically."
    )
version_path = root / "PSTACK_VERSION"
if not version_path.is_file() or not version_path.read_text().strip():
    raise SystemExit(
        "pstack-present: PSTACK_VERSION is missing or empty. "
        "Rule: Cloud agents get pstack automatically."
    )
checksums = root / "CHECKSUMS"
if not checksums.is_file():
    raise SystemExit(
        "pstack-present: CHECKSUMS is missing. "
        "Rule: Cloud agents get pstack automatically."
    )

declared: dict[str, str] = {}
for number, line in enumerate(checksums.read_text().splitlines(), 1):
    if not line.strip():
        continue
    if len(line) < 66 or line[64:66] != "  " or any(c not in "0123456789abcdef" for c in line[:64]):
        raise SystemExit(
            f"pstack-present: CHECKSUMS line {number} is malformed. "
            "Rule: Cloud agents get pstack automatically."
        )
    digest, rel = line[:64], line[66:]
    if rel in declared:
        raise SystemExit(
            f"pstack-present: CHECKSUMS lists {rel} twice. "
            "Rule: Cloud agents get pstack automatically."
        )
    declared[rel] = digest

actual: dict[str, str] = {}
for dirpath, dirnames, filenames in os.walk(root):
    dirnames.sort()
    for name in filenames:
        if name == "CHECKSUMS":
            continue
        path = Path(dirpath) / name
        rel = path.relative_to(root).as_posix()
        if path.is_symlink():
            raise SystemExit(
                f"pstack-present: symlink not allowed: {rel}. "
                "Rule: Cloud agents get pstack automatically."
            )
        actual[rel] = hashlib.sha256(path.read_bytes()).hexdigest()

missing = sorted(set(declared) - set(actual))
extra = sorted(set(actual) - set(declared))
mismatch = sorted(rel for rel in declared.keys() & actual.keys() if declared[rel] != actual[rel])
if missing or extra or mismatch:
    for rel in missing:
        print(f"pstack-present: CHECKSUMS lists missing file {rel}", file=sys.stderr)
    for rel in extra:
        print(f"pstack-present: file not in CHECKSUMS: {rel}", file=sys.stderr)
    for rel in mismatch:
        print(f"pstack-present: sha256 mismatch {rel}", file=sys.stderr)
    raise SystemExit(
        "pstack-present: vendored snapshot does not match CHECKSUMS. "
        "Rule: Cloud agents get pstack automatically."
    )

print(f"pstack-present: ok {version_path.read_text().strip()} ({len(actual)} files)")
PY
