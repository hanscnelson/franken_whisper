#!/usr/bin/env bash
# Fail unless the PR body has a filled ## Verification section.
set -euo pipefail

body_file=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --body-file)
      body_file="${2:?--body-file needs a path}"
      shift 2
      ;;
    -h|--help)
      echo "usage: scripts/check-pr-evidence.sh [--body-file path]" >&2
      exit 2
      ;;
    *)
      echo "check-pr-evidence: unknown argument $1" >&2
      exit 2
      ;;
  esac
done

python3 - "$body_file" <<'PY'
import json
import os
import re
import sys
from pathlib import Path

RULE = "Rule: Every PR carries verification evidence."
HEADERS = ("Predicate", "Commands", "Output", "Verdict")
PLACEHOLDERS = {
    "verified | not verified | inconclusive",
    "todo",
    "tbd",
    "fixme",
    "...",
    "placeholder",
    "<placeholder>",
}


def fail(message: str) -> None:
    raise SystemExit(f"pr-evidence: {message} {RULE}")


def load_body() -> str:
    explicit = sys.argv[1]
    if explicit:
        return Path(explicit).read_text()
    event_path = os.environ.get("GITHUB_EVENT_PATH", "")
    if not event_path:
        fail("no PR body. Pass --body-file or run in GitHub Actions.")
    event = json.loads(Path(event_path).read_text())
    pull_request = event.get("pull_request")
    if not isinstance(pull_request, dict):
        fail("event has no pull_request body.")
    body = pull_request.get("body")
    return body if isinstance(body, str) else ""


def section(body: str) -> str:
    lines = body.replace("\r\n", "\n").replace("\r", "\n").split("\n")
    start = None
    for index, line in enumerate(lines):
        if line.strip() == "## Verification":
            start = index + 1
            break
    if start is None:
        fail("PR body lacks ## Verification.")
    end = len(lines)
    for index in range(start, len(lines)):
        stripped = lines[index].strip()
        if stripped.startswith("## ") and stripped != "## Verification":
            end = index
            break
    return "\n".join(lines[start:end])


def header_positions(text: str) -> dict[str, int]:
    lines = text.split("\n")
    positions: dict[str, int] = {}
    in_fence = False
    for index, line in enumerate(lines):
        if line.strip().startswith("```"):
            in_fence = not in_fence
            continue
        if in_fence:
            continue
        for name in HEADERS:
            if line.startswith(name + ":") and name not in positions:
                positions[name] = index
    return positions


def field_text(text: str, positions: dict[str, int], name: str) -> str:
    lines = text.split("\n")
    start = positions[name]
    later = [positions[other] for other in HEADERS if positions[other] > start]
    end = min(later) if later else len(lines)
    inline = lines[start].split(":", 1)[1]
    rest = lines[start + 1 : end]
    return (inline + ("\n" + "\n".join(rest) if rest else "")).strip()


def placeholder_reason(value: str) -> str | None:
    if not value.strip():
        return "empty"
    normalized = re.sub(r"\s+", " ", value.strip()).lower()
    if normalized in PLACEHOLDERS or re.fullmatch(r"<[^>\n]+>", value.strip()):
        return "placeholder"
    return None


body = load_body()
block = section(body)
positions = header_positions(block)
missing = [name for name in HEADERS if name not in positions]
if missing:
    fail("missing field(s): " + ", ".join(missing) + ".")
order = [positions[name] for name in HEADERS]
if order != sorted(order):
    fail("Verification fields are out of order. Expected Predicate, Commands, Output, Verdict.")
for name in HEADERS:
    reason = placeholder_reason(field_text(block, positions, name))
    if reason:
        fail(f"{name} is {reason}.")
print("pr-evidence: ok")
PY
