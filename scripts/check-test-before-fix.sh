#!/usr/bin/env bash
# On a bug-labeled PR, require a test change. Run Python tests against base.
set -euo pipefail

SCRIPT=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")

self_test() {
  local tmp base head
  tmp=$(mktemp -d)
  git init -b main "$tmp/repo" >/dev/null
  (
    cd "$tmp/repo"
    git config user.email "pstack-self-test@example.com"
    git config user.name "pstack-self-test"
    printf 'VALUE = 1\n' > pkg.py
    git add pkg.py
    git commit -m base >/dev/null
  )
  base=$(git -C "$tmp/repo" rev-parse HEAD)

  git -C "$tmp/repo" checkout -b no-test >/dev/null
  printf 'VALUE = 2\n' > "$tmp/repo/pkg.py"
  git -C "$tmp/repo" add pkg.py
  git -C "$tmp/repo" commit -m 'change without a test' >/dev/null
  head=$(git -C "$tmp/repo" rev-parse HEAD)
  if "$SCRIPT" --no-fetch --base "$base" --head "$head" --labels bug --repo "$tmp/repo"; then
    echo "test-before-fix self-test: expected failure when a bug change has no test" >&2
    exit 1
  fi

  git -C "$tmp/repo" checkout -b passes-on-base "$base" >/dev/null
  printf 'VALUE = 2\n' > "$tmp/repo/pkg.py"
  cat > "$tmp/repo/test_pkg.py" <<'EOF'
import unittest
import pkg

class T(unittest.TestCase):
    def test_value(self):
        self.assertEqual(pkg.VALUE, 1)
EOF
  git -C "$tmp/repo" add pkg.py test_pkg.py
  git -C "$tmp/repo" commit -m 'test already true on base' >/dev/null
  head=$(git -C "$tmp/repo" rev-parse HEAD)
  if "$SCRIPT" --no-fetch --base "$base" --head "$head" --labels bug --repo "$tmp/repo"; then
    echo "test-before-fix self-test: expected failure when the new test passes on base" >&2
    exit 1
  fi

  git -C "$tmp/repo" checkout -b fails-on-base "$base" >/dev/null
  printf 'VALUE = 2\n' > "$tmp/repo/pkg.py"
  cat > "$tmp/repo/test_pkg.py" <<'EOF'
import unittest
import pkg

class T(unittest.TestCase):
    def test_value(self):
        self.assertEqual(pkg.VALUE, 2)
EOF
  git -C "$tmp/repo" add pkg.py test_pkg.py
  git -C "$tmp/repo" commit -m 'test fails until the fix' >/dev/null
  head=$(git -C "$tmp/repo" rev-parse HEAD)
  "$SCRIPT" --no-fetch --base "$base" --head "$head" --labels bug --repo "$tmp/repo"

  if ! "$SCRIPT" --no-fetch --base "$base" --head "$head" --labels chore --repo "$tmp/repo"; then
    echo "test-before-fix self-test: a PR without the bug label must pass" >&2
    exit 1
  fi
  echo "test-before-fix self-test: ok"
}

if [[ "${1:-}" == "--self-test" ]]; then
  self_test
  exit 0
fi

no_fetch=0
base_sha="${BASE_SHA:-}"
head_sha="${HEAD_SHA:-}"
labels="${LABELS:-}"
repo=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-fetch)
      no_fetch=1
      shift
      ;;
    --base)
      base_sha="${2:?--base needs a sha}"
      shift 2
      ;;
    --head)
      head_sha="${2:?--head needs a sha}"
      shift 2
      ;;
    --labels)
      labels="${2:?--labels needs a comma-separated list}"
      shift 2
      ;;
    --repo)
      repo="${2:?--repo needs a path}"
      shift 2
      ;;
    -h|--help)
      echo "usage: scripts/check-test-before-fix.sh [--self-test | --base sha --head sha --labels bug]" >&2
      exit 2
      ;;
    *)
      echo "test-before-fix: unknown argument $1" >&2
      exit 2
      ;;
  esac
done

if [[ -n "$repo" ]]; then
  cd "$repo"
fi

export TBF_NO_FETCH="$no_fetch"
export TBF_BASE_SHA="$base_sha"
export TBF_HEAD_SHA="$head_sha"
export TBF_LABELS="$labels"
export BASE_REF="${BASE_REF:-}"

python3 - <<'PY'
import importlib.util
import json
import os
import subprocess
import sys
import unittest
from pathlib import Path

RULE = "Rule: Bug fixes land with a failing test first."
CARGO_REASON = (
    "test-before-fix: cargo tests are not executed against base. "
    "The native engine build fails on Linux without ../frankentorch, release "
    "qualification is a multi-hour job, and unit tests inside src/ share a file "
    "with the fix so they cannot be run on base source alone. "
    "Python unittest files are executed. " + RULE
)


def fail(message: str) -> None:
    raise SystemExit(f"test-before-fix: {message} {RULE}")


def git(*args: str, check: bool = True) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        ["git", *args],
        check=check,
        text=True,
        capture_output=True,
    )


def event() -> dict:
    path = os.environ.get("GITHUB_EVENT_PATH", "")
    if not path:
        return {}
    return json.loads(Path(path).read_text())


def label_names() -> list[str]:
    explicit = os.environ.get("TBF_LABELS", "")
    if explicit:
        return [part.strip() for part in explicit.split(",") if part.strip()]
    pull_request = event().get("pull_request") or {}
    return [item.get("name", "") for item in pull_request.get("labels") or []]


def resolve_sha(name: str, env_key: str, event_path: tuple[str, ...]) -> str:
    explicit = os.environ.get(env_key, "")
    if explicit:
        return explicit
    cursor = event()
    for key in event_path:
        if not isinstance(cursor, dict) or key not in cursor:
            cursor = None
            break
        cursor = cursor[key]
    if isinstance(cursor, str) and cursor:
        return cursor
    fail(f"missing {name} sha.")


def is_test(path: str) -> bool:
    name = path.rsplit("/", 1)[-1]
    if path.startswith("tests/") or "/tests/" in path:
        return True
    if name.startswith("test_") and name.endswith(".py"):
        return True
    return name.endswith(("_test.py", "_test.rs", "_tests.rs"))


def is_python_test(path: str) -> bool:
    return path.endswith(".py") and is_test(path)


def changed_files(base: str, head: str) -> list[str]:
    result = git("diff", "--name-only", "--diff-filter=ACMR", f"{base}...{head}")
    return [line for line in result.stdout.splitlines() if line]


def run_python_test(repo: Path, rel: str) -> int:
    path = repo / rel
    if not path.is_file():
        print(f"test-before-fix: missing {rel} in {repo}", file=sys.stderr)
        return 1
    before_modules = set(sys.modules)
    before_path = list(sys.path)
    sys.path.insert(0, str(path.parent))
    try:
        spec = importlib.util.spec_from_file_location("pstack_case_under_test", path)
        if spec is None or spec.loader is None:
            print(f"test-before-fix: cannot load {rel}", file=sys.stderr)
            return 1
        module = importlib.util.module_from_spec(spec)
        try:
            spec.loader.exec_module(module)
        except Exception as exc:
            print(f"test-before-fix: load error {rel}: {exc}", file=sys.stderr)
            return 1
        suite = unittest.defaultTestLoader.loadTestsFromModule(module)
        if suite.countTestCases() == 0:
            print(f"test-before-fix: no unittest cases in {rel}", file=sys.stderr)
            return 1
        result = unittest.TextTestRunner(verbosity=1).run(suite)
        return 0 if result.wasSuccessful() else 1
    finally:
        sys.path[:] = before_path
        for name in list(sys.modules):
            if name not in before_modules:
                del sys.modules[name]


def with_worktree(sha: str) -> Path:
    path = Path(subprocess.check_output(["mktemp", "-d"], text=True).strip())
    path.rmdir()
    git("worktree", "add", "--detach", str(path), sha)
    return path


def remove_worktree(path: Path) -> None:
    resolved = str(path.resolve())
    if not resolved.startswith("/tmp/"):
        raise SystemExit(f"test-before-fix: refusing to remove {resolved}")
    git("worktree", "remove", "--force", resolved, check=False)
    if path.exists():
        subprocess.run(["rm", "-rf", resolved], check=False)


labels = label_names()
if "bug" not in labels:
    print("test-before-fix: no bug label, skip")
    raise SystemExit(0)

base = resolve_sha("base", "TBF_BASE_SHA", ("pull_request", "base", "sha"))
head = resolve_sha("head", "TBF_HEAD_SHA", ("pull_request", "head", "sha"))
if os.environ.get("TBF_NO_FETCH", "0") != "1":
    ref = os.environ.get("BASE_REF") or "main"
    fetched = subprocess.run(
        ["git", "fetch", "--no-tags", "origin", ref],
        text=True,
    )
    if fetched.returncode != 0:
        fail(f"git fetch origin {ref} failed.")

files = changed_files(base, head)
tests = [path for path in files if is_test(path)]
if not tests:
    fail("bug-labeled PR changes no test file.")

python_tests = [path for path in tests if is_python_test(path)]
other_tests = [path for path in tests if path not in python_tests]
if other_tests:
    print(CARGO_REASON)
    print("test-before-fix: file-changed half only for " + ", ".join(other_tests))

if not python_tests:
    print("test-before-fix: ok (test file changed; no Python unittest to execute)")
    raise SystemExit(0)

base_tree = with_worktree(base)
head_tree = with_worktree(head)
try:
    for rel in python_tests:
        source = head_tree / rel
        target = base_tree / rel
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(source.read_bytes())
        base_result = run_python_test(base_tree, rel)
        if base_result == 0:
            fail(f"{rel} passed on base {base}. A bug-fix test must fail there.")
        head_result = run_python_test(head_tree, rel)
        if head_result != 0:
            fail(f"{rel} did not pass on head {head}.")
        print(f"test-before-fix: {rel} failed on base and passed on head")
finally:
    remove_worktree(base_tree)
    remove_worktree(head_tree)

print("test-before-fix: ok")
PY
