#!/bin/sh
# .service.lock lives in the module directory and survives a reboot. A lock whose recorded
# boot_id is from another boot is stale and must be reclaimed whatever else it holds; a lock
# of the current boot in a partial shape must be left alone, and of several workers racing
# for one stale lock at most one may start the daemon.
set -eu

ROOT=$(unset CDPATH; cd -- "$(dirname -- "$0")/.." && pwd)
SERVICE="$ROOT/module/service.sh"
TMP=${TMPDIR:-/tmp}/tsoss-stale-boot-test.$$
trap 'rm -rf "$TMP"' EXIT HUP INT TERM
mkdir -p "$TMP"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

CURRENT_BOOT=$(cat /proc/sys/kernel/random/boot_id)
OLD_BOOT=00000000-0000-4000-8000-000000000001
[ "$OLD_BOOT" != "$CURRENT_BOOT" ] || OLD_BOOT=00000000-0000-4000-8000-000000000002
DEAD_PID=99999999

# setup_case <name>: module dir with service.sh and a mock daemon that records each run.
setup_case() {
  dir="$TMP/$1"
  mkdir -p "$dir/.service.lock"
  cp "$SERVICE" "$dir/service.sh"
  cat > "$dir/daemon" <<'MOCK'
#!/bin/sh
echo run >> "$MOCK_LOG"
[ -n "${MOCK_SLEEP:-}" ] && sleep "$MOCK_SLEEP"
exit 7
MOCK
  chmod +x "$dir/daemon"
}

# run_worker <name>: one foreground worker with a failure budget of one run.
run_worker() {
  dir="$TMP/$1"
  (cd "$dir" && MOCK_LOG="$dir/runs" TSOSS_SUPERVISOR_MAX_FAILURES=1 TSOSS_SUPERVISOR_FOREGROUND=true \
    sh ./service.sh --worker) > "$dir/log" 2>&1 || true
}

runs() { if [ -f "$TMP/$1/runs" ]; then wc -l < "$TMP/$1/runs" | tr -d ' '; else echo 0; fi; }

expect_reclaimed() {
  [ "$(runs "$1")" -eq 1 ] || fail "$1: lock from a previous boot was not reclaimed (daemon runs: $(runs "$1"))"
  [ ! -e "$TMP/$1/.service.lock" ] || fail "$1: reclaimed lock was not released"
}

expect_untouched() {
  [ "$(runs "$1")" -eq 0 ] || fail "$1: daemon started over a lock of the current boot"
  [ -d "$TMP/$1/.service.lock" ] || fail "$1: lock of the current boot was removed"
}

# --- previous boot: reclaimed whatever is missing or left over ---
setup_case old-no-starttime
printf '%s\n' "$DEAD_PID" > "$TMP/old-no-starttime/.service.lock/pid"
printf '%s\n' "$OLD_BOOT" > "$TMP/old-no-starttime/.service.lock/boot_id"
run_worker old-no-starttime
expect_reclaimed old-no-starttime

setup_case old-with-reap
printf '%s\n' "$DEAD_PID" > "$TMP/old-with-reap/.service.lock/pid"
printf '%s\n' "$OLD_BOOT" > "$TMP/old-with-reap/.service.lock/boot_id"
printf '1\n' > "$TMP/old-with-reap/.service.lock/starttime"
mkdir "$TMP/old-with-reap/.service.lock/reap"
run_worker old-with-reap
expect_reclaimed old-with-reap

setup_case old-boot-id-only
printf '%s\n' "$OLD_BOOT" > "$TMP/old-boot-id-only/.service.lock/boot_id"
run_worker old-boot-id-only
expect_reclaimed old-boot-id-only

# --- current boot: partial shapes stay as they are ---
setup_case cur-no-starttime
printf '%s\n' "$DEAD_PID" > "$TMP/cur-no-starttime/.service.lock/pid"
printf '%s\n' "$CURRENT_BOOT" > "$TMP/cur-no-starttime/.service.lock/boot_id"
run_worker cur-no-starttime
expect_untouched cur-no-starttime
[ -f "$TMP/cur-no-starttime/.service.lock/pid" ] || fail "cur-no-starttime: lock contents changed"

setup_case cur-with-reap
printf '%s\n' "$DEAD_PID" > "$TMP/cur-with-reap/.service.lock/pid"
printf '%s\n' "$CURRENT_BOOT" > "$TMP/cur-with-reap/.service.lock/boot_id"
printf '1\n' > "$TMP/cur-with-reap/.service.lock/starttime"
mkdir "$TMP/cur-with-reap/.service.lock/reap"
run_worker cur-with-reap
expect_untouched cur-with-reap
[ -d "$TMP/cur-with-reap/.service.lock/reap" ] || fail "cur-with-reap: another worker's reap dir was removed"

setup_case cur-no-pid
run_worker cur-no-pid
expect_untouched cur-no-pid

# --- a reaper of this boot already holds the stale lock: another worker stays out ---
setup_case old-reaped-now
printf '%s\n' "$DEAD_PID" > "$TMP/old-reaped-now/.service.lock/pid"
printf '%s\n' "$OLD_BOOT" > "$TMP/old-reaped-now/.service.lock/boot_id"
printf '1\n' > "$TMP/old-reaped-now/.service.lock/starttime"
mkdir "$TMP/old-reaped-now/.service.lock/reap.$CURRENT_BOOT"
run_worker old-reaped-now
expect_untouched old-reaped-now
[ -d "$TMP/old-reaped-now/.service.lock/reap.$CURRENT_BOOT" ] || fail "old-reaped-now: the other reaper's dir was removed"

# --- workers racing for one stale lock: at most one starts the daemon ---
setup_case race
printf '%s\n' "$DEAD_PID" > "$TMP/race/.service.lock/pid"
printf '%s\n' "$OLD_BOOT" > "$TMP/race/.service.lock/boot_id"
printf '1\n' > "$TMP/race/.service.lock/starttime"
export MOCK_SLEEP=2
pids=
for n in 1 2 3 4; do
  run_worker race &
  pids="$pids $!"
done
for p in $pids; do wait "$p" || true; done
unset MOCK_SLEEP
[ "$(runs race)" -eq 1 ] || fail "race: $(runs race) workers started the daemon over one stale lock"

echo 'PASS: previous-boot locks reclaimed, current-boot partial locks untouched, one winner per stale lock'
