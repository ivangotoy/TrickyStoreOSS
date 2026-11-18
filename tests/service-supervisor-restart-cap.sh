#!/bin/sh
# Runs that outlive the stability window reset the failure budget. A daemon that keeps
# exiting after a slow start (e.g. killed by the injector timeout) must still stop after
# TSOSS_SUPERVISOR_MAX_RESTARTS such runs, while a run of TSOSS_SUPERVISOR_HEALTHY_SECONDS
# clears that count and quick failures keep their own TSOSS_SUPERVISOR_MAX_FAILURES budget.
set -eu

ROOT=$(unset CDPATH; cd -- "$(dirname -- "$0")/.." && pwd)
SERVICE="$ROOT/module/service.sh"
TMP=${TMPDIR:-/tmp}/tsoss-restart-cap-test.$$
worker=
trap 'if [ -n "$worker" ]; then kill "$worker" 2>/dev/null || true; fi; rm -rf "$TMP"' EXIT HUP INT TERM
mkdir -p "$TMP"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

# run_worker <name> <limit seconds> <env...>: runs the foreground worker with a mock daemon
# driven by MOCK_PLAN ("<seconds to run> per invocation", last entry repeats); prints status count.
run_worker() {
  name=$1 limit=$2
  shift 2
  dir="$TMP/$name"
  mkdir -p "$dir"
  cp "$SERVICE" "$dir/service.sh"
  cat > "$dir/daemon" <<'MOCK'
#!/bin/sh
printf '%s\n' "$*" >> "$MOCK_LOG"
n=$(wc -l < "$MOCK_LOG" | tr -d ' ')
set -- $MOCK_PLAN
while [ "$n" -gt 1 ] && [ "$#" -gt 1 ]; do shift; n=$((n - 1)); done
[ "$1" -gt 0 ] && sleep "$1"
exit 1
MOCK
  chmod +x "$dir/daemon"
  export MOCK_LOG="$dir/invocations"
  : > "$MOCK_LOG"
  (cd "$dir" && exec env "$@" TSOSS_SUPERVISOR_BACKOFF_MAX=1 TSOSS_SUPERVISOR_FOREGROUND=true \
    sh ./service.sh --worker) > "$dir/log" 2>&1 &
  worker=$!
  waited=0
  while kill -0 "$worker" 2>/dev/null && [ "$waited" -lt "$limit" ]; do
    sleep 1
    waited=$((waited + 1))
  done
  if kill -0 "$worker" 2>/dev/null; then
    # traps are not inherited by this command-substitution subshell: stop the worker here
    kill "$worker" 2>/dev/null || true
    fail "$name: supervisor still restarting after ${waited}s ($(wc -l < "$MOCK_LOG" | tr -d ' ') runs): restart loop not bounded"
  fi
  set +e
  wait "$worker"
  status=$?
  set -e
  worker=
  [ ! -e "$dir/.service.lock" ] || fail "$name: supervisor left its lock"
  printf '%s %s\n' "$status" "$(wc -l < "$MOCK_LOG" | tr -d ' ')"
}

# Slow exits (1 s, past a 1 s stability window) stop after 3 runs.
result=$(MOCK_PLAN=1 run_worker slow 15 TSOSS_SUPERVISOR_MAX_RESTARTS=3 TSOSS_SUPERVISOR_STABILITY_SECONDS=1)
[ "${result%% *}" -ne 0 ] || fail "slow: capped supervisor should exit non-zero"
[ "${result##* }" -eq 3 ] || fail "slow: expected 3 daemon runs, got ${result##* }"
grep -q 'restart limit reached (3 runs past the stability window)' "$TMP/slow/log" || fail "slow: missing restart limit log line"

# Quick failures keep their own budget even when it is larger than the restart cap.
result=$(MOCK_PLAN=0 run_worker quick 20 TSOSS_SUPERVISOR_MAX_RESTARTS=2 TSOSS_SUPERVISOR_MAX_FAILURES=5 TSOSS_SUPERVISOR_STABILITY_SECONDS=30)
[ "${result##* }" -eq 5 ] || fail "quick: expected 5 daemon runs (failure budget), got ${result##* }"
grep -q 'failure budget exhausted' "$TMP/quick/log" || fail "quick: missing failure budget log line"

# Healthy runs (3 s >= HEALTHY_SECONDS) clear the count: 4 healthy runs, then 1 slow run reaches the cap of 2.
result=$(MOCK_PLAN="3 3 3 3 1" run_worker healthy 40 TSOSS_SUPERVISOR_MAX_RESTARTS=2 TSOSS_SUPERVISOR_STABILITY_SECONDS=1 TSOSS_SUPERVISOR_HEALTHY_SECONDS=3)
[ "${result##* }" -eq 5 ] || fail "healthy: expected 5 daemon runs (healthy runs reset the count), got ${result##* }"
grep -q 'restart limit reached (2 runs past the stability window)' "$TMP/healthy/log" || fail "healthy: missing restart limit log line"

echo 'PASS: restart cap for slow exits, quick-failure budget kept, healthy runs reset the cap'
