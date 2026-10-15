#!/usr/bin/env bash
# Refuse a release build unless HEAD is merged main, the tree is clean, and disk remains.
set -euo pipefail

SCRIPT=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")
RULE="Production images come only from merged main"
DISK_RULE="Parallel agents don't share a branch or disk budget"

fail() {
  echo "check-build-from-main: $* Rule: ${RULE}." >&2
  exit 1
}

free_mb() {
  python3 - <<'PY'
import shutil
print(shutil.disk_usage(".").free // (1024 * 1024))
PY
}

check_disk() {
  local avail min
  avail=$(free_mb)
  min=${FW_MIN_FREE_MB:-2048}
  echo "check-build-from-main: free disk ${avail} MiB (minimum ${min} MiB)." >&2
  if (( avail < min )); then
    echo "check-build-from-main: refusing build, ${avail} MiB free is below ${min} MiB. Rule: ${DISK_RULE}." >&2
    exit 1
  fi
}

package_version() {
  python3 - <<'PY'
import re
from pathlib import Path
path = Path("Cargo.toml")
if not path.exists():
    raise SystemExit(0)
text = path.read_text()
match = re.search(r"(?ms)^\[package\]\n(.*?)(?:^\[|\Z)", text)
if not match:
    raise SystemExit(0)
version = re.search(r'(?m)^version\s*=\s*"([^"]+)"\s*$', match.group(1))
if version:
    print(version.group(1))
PY
}

fetch_main() {
  export GIT_TERMINAL_PROMPT=0
  if ! git remote get-url origin >/dev/null 2>&1; then
    fail "no origin remote."
  fi
  if ! git fetch --no-tags origin main; then
    fail "git fetch origin main failed."
  fi
  if [[ "$(git rev-parse --is-shallow-repository)" == "true" ]]; then
    git fetch --no-tags --unshallow origin main \
      || git fetch --no-tags --unshallow origin \
      || true
  fi
  if ! git rev-parse --verify --quiet origin/main >/dev/null; then
    fail "origin/main is missing after fetch."
  fi
}

print_label() {
  local sha
  sha=$(git rev-parse HEAD)
  echo "org.opencontainers.image.revision=${sha}"
}

check_version_tag() {
  local tag version
  tag=${FW_IMAGE_TAG:-}
  version=$(package_version || true)
  if [[ -z "$version" ]]; then
    echo "check-build-from-main: no Cargo.toml package version and no producer_version. Tag equality skipped." >&2
    return 0
  fi
  echo "check-build-from-main: version source is Cargo.toml package version ${version}. producer_version is absent." >&2
  if [[ -z "$tag" ]]; then
    echo "check-build-from-main: FW_IMAGE_TAG is unset. Tag equality skipped." >&2
    return 0
  fi
  if [[ "$tag" != "$version" && "$tag" != "v${version}" ]]; then
    fail "image tag ${tag} does not equal version source ${version}."
  fi
}

cmd_check() {
  local sha
  cd "$(git rev-parse --show-toplevel)"
  check_disk
  if [[ "${FW_ALLOW_NON_MAIN_IMAGE:-}" == "1" ]]; then
    echo "check-build-from-main: OVERRIDE FW_ALLOW_NON_MAIN_IMAGE=1. Local dev image only. This image must never be pushed. Rule: ${RULE}." >&2
    print_label
    return 0
  fi
  fetch_main
  sha=$(git rev-parse HEAD)
  if ! git merge-base --is-ancestor HEAD origin/main; then
    fail "refusing build. HEAD ${sha} is not an ancestor of origin/main."
  fi
  if [[ -n "$(git status --porcelain)" ]]; then
    fail "refusing build. git status --porcelain is not empty."
  fi
  check_version_tag
  print_label
}

cmd_push() {
  if [[ "${FW_ALLOW_NON_MAIN_IMAGE:-}" == "1" ]]; then
    echo "check-build-from-main: refusing push. FW_ALLOW_NON_MAIN_IMAGE=1 marks a local dev image that is never pushed. Rule: ${RULE}." >&2
    exit 1
  fi
  cmd_check
}

self_test() {
  local tmp origin repo shallow base label out
  tmp=$(mktemp -d)
  origin="$tmp/origin.git"
  repo="$tmp/repo"
  git init --bare -b main "$origin" >/dev/null
  git init -b main "$repo" >/dev/null
  git -C "$repo" config user.email "pstack-self-test@example.com"
  git -C "$repo" config user.name "pstack-self-test"
  git -C "$repo" remote add origin "$origin"
  cat > "$repo/Cargo.toml" <<'EOF'
[package]
name = "selftest"
version = "0.0.1"
EOF
  printf 'seed\n' > "$repo/README"
  git -C "$repo" add Cargo.toml README
  git -C "$repo" commit -m base >/dev/null
  git -C "$repo" push -u origin main >/dev/null
  base=$(git -C "$repo" rev-parse HEAD)

  label=$(cd "$repo" && "$SCRIPT" check)
  if [[ "$label" != "org.opencontainers.image.revision=${base}" ]]; then
    echo "self-test: main did not print the revision label: $label" >&2
    exit 1
  fi
  (cd "$repo" && FW_IMAGE_TAG=0.0.1 "$SCRIPT" check >/dev/null)
  if (cd "$repo" && FW_IMAGE_TAG=9.9.9 "$SCRIPT" check >/dev/null); then
    echo "self-test: mismatched image tag was accepted" >&2
    exit 1
  fi

  git -C "$repo" checkout -b feature >/dev/null
  printf 'more\n' >> "$repo/README"
  git -C "$repo" add README
  git -C "$repo" commit -m feature >/dev/null
  if (cd "$repo" && "$SCRIPT" check >/dev/null); then
    echo "self-test: feature branch was accepted" >&2
    exit 1
  fi
  (cd "$repo" && "$SCRIPT" check >/tmp/pstack-feature-check.err 2>&1 || true)
  if ! grep -q "not an ancestor of origin/main" /tmp/pstack-feature-check.err; then
    echo "self-test: feature refusal did not name ancestry" >&2
    cat /tmp/pstack-feature-check.err >&2
    exit 1
  fi
  if ! grep -q "$RULE" /tmp/pstack-feature-check.err; then
    echo "self-test: feature refusal did not name the rule" >&2
    exit 1
  fi

  if (cd "$repo" && FW_ALLOW_NON_MAIN_IMAGE=1 "$SCRIPT" check >/dev/null); then
    :
  else
    echo "self-test: local override was refused" >&2
    exit 1
  fi
  (cd "$repo" && FW_ALLOW_NON_MAIN_IMAGE=1 "$SCRIPT" check >/tmp/pstack-override.err 2>&1)
  if ! grep -q "OVERRIDE FW_ALLOW_NON_MAIN_IMAGE=1" /tmp/pstack-override.err; then
    echo "self-test: override was not logged" >&2
    exit 1
  fi
  if (cd "$repo" && FW_ALLOW_NON_MAIN_IMAGE=1 "$SCRIPT" push >/dev/null); then
    echo "self-test: push was allowed under the local override" >&2
    exit 1
  fi

  git -C "$repo" checkout main >/dev/null
  printf 'dirty\n' >> "$repo/README"
  if (cd "$repo" && "$SCRIPT" check >/dev/null); then
    echo "self-test: dirty main was accepted" >&2
    exit 1
  fi
  git -C "$repo" checkout -- README

  if (cd "$repo" && FW_MIN_FREE_MB=99999999 "$SCRIPT" check >/dev/null); then
    echo "self-test: low-disk floor was accepted" >&2
    exit 1
  fi

  shallow="$tmp/shallow"
  # A path clone ignores --depth. file:// keeps the clone shallow.
  git clone --depth 1 "file://${origin}" "$shallow" >/dev/null
  git -C "$shallow" config user.email "pstack-self-test@example.com"
  git -C "$shallow" config user.name "pstack-self-test"
  out=$(cd "$shallow" && "$SCRIPT" check)
  if [[ "$out" != "org.opencontainers.image.revision=${base}" ]]; then
    echo "self-test: shallow main did not pass: $out" >&2
    exit 1
  fi
  echo "check-build-from-main self-test: ok"
}

prove_live() {
  local head_err head_status main_wt main_status repo
  repo=$(git rev-parse --show-toplevel)
  head_err=$(mktemp)
  set +e
  (cd "$repo" && "$SCRIPT" check >/dev/null 2>"$head_err")
  head_status=$?
  set -e
  echo "image-from-main: current HEAD $(git -C "$repo" rev-parse HEAD) gate exit ${head_status}"
  cat "$head_err" >&2
  if git -C "$repo" merge-base --is-ancestor HEAD origin/main; then
    if [[ -n "$(git -C "$repo" status --porcelain)" ]]; then
      if [[ "$head_status" -eq 0 ]] || ! grep -q "porcelain" "$head_err"; then
        echo "image-from-main: dirty ancestor was not refused" >&2
        exit 1
      fi
    elif [[ "$head_status" -ne 0 ]]; then
      echo "image-from-main: gate rejected a clean ancestor of origin/main" >&2
      exit 1
    fi
  else
    if [[ "$head_status" -eq 0 ]]; then
      echo "image-from-main: gate accepted HEAD that is not an ancestor of origin/main" >&2
      exit 1
    fi
    if ! grep -q "not an ancestor of origin/main" "$head_err"; then
      echo "image-from-main: refusal did not report ancestry" >&2
      exit 1
    fi
  fi

  main_wt=$(mktemp -u)
  git -C "$repo" fetch --no-tags origin main
  git -C "$repo" worktree add --detach "$main_wt" origin/main >/dev/null
  set +e
  (cd "$main_wt" && "$SCRIPT" check >/tmp/pstack-main-label.out 2>/tmp/pstack-main-label.err)
  main_status=$?
  set -e
  echo "image-from-main: origin/main $(git -C "$main_wt" rev-parse HEAD) gate exit ${main_status}"
  cat /tmp/pstack-main-label.err >&2
  cat /tmp/pstack-main-label.out
  git -C "$repo" worktree remove --force "$main_wt"
  if [[ "$main_status" -ne 0 ]]; then
    echo "image-from-main: gate rejected origin/main" >&2
    exit 1
  fi
  echo "image-from-main: prove-live ok"
}

usage() {
  echo "usage: scripts/check-build-from-main.sh [check|push|self-test|prove-live]" >&2
}

cmd=${1:-check}
case "$cmd" in
  check) cmd_check ;;
  push) cmd_push ;;
  self-test) self_test ;;
  prove-live) prove_live ;;
  -h|--help) usage ;;
  *)
    usage
    exit 2
    ;;
esac
