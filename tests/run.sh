#!/bin/sh
# Runs every host-side check: the shell tests and the syntax checks of
# module scripts, CI scripts, workflows and update feeds. No device, no network.
set -u

ROOT=$(unset CDPATH; cd -- "$(dirname -- "$0")/.." && pwd)
failures=0

pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*"; failures=$((failures + 1)); }
skip() { echo "SKIP: $*"; }

run_test() {
  if out=$(sh "$ROOT/tests/$1" 2>&1); then
    printf '%s\n' "$out"
    pass "$1"
  else
    printf '%s\n' "$out"
    fail "$1"
  fi
}

for f in module/customize.sh module/post-fs-data.sh module/service.sh module/daemon \
  module/META-INF/com/google/android/update-binary; do
  if sh -n "$ROOT/$f"; then pass "sh -n $f"; else fail "sh -n $f"; fi
done

if command -v bash >/dev/null 2>&1; then
  if bash -n "$ROOT/.forgejo/module-ci.sh"; then
    pass "bash -n .forgejo/module-ci.sh"
  else
    fail "bash -n .forgejo/module-ci.sh"
  fi
else
  skip "bash -n .forgejo/module-ci.sh (bash not installed)"
fi

if command -v python3 >/dev/null 2>&1 && python3 -I -c 'import yaml' 2>/dev/null; then
  for f in "$ROOT"/.forgejo/workflows/*.yml "$ROOT"/.github/workflows/*.yml; do
    rel=${f#"$ROOT"/}
    if python3 -I -c 'import sys, yaml; yaml.safe_load(open(sys.argv[1]))' "$f"; then
      pass "yaml $rel"
    else
      fail "yaml $rel"
    fi
  done
else
  skip "yaml parse (python3 with PyYAML not installed)"
fi

if command -v python3 >/dev/null 2>&1; then
  for f in update.json .forgejo/update.json; do
    if python3 -I -c 'import sys, json; json.load(open(sys.argv[1]))' "$ROOT/$f"; then
      pass "json $f"
    else
      fail "json $f"
    fi
  done
else
  skip "json parse (python3 not installed)"
fi

run_test service-supervisor-faults.sh
run_test service-supervisor-restart-cap.sh
run_test service-supervisor-stale-boot.sh
run_test module-scripts.sh
run_test release-cleanup.sh
run_test build-step.sh
run_test workflow-dispatch.sh

if [ "$failures" -ne 0 ]; then
  echo "run.sh: $failures check(s) failed"
  exit 1
fi
echo "run.sh: all checks passed"
