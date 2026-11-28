#!/bin/sh
# .service.lock lives in the module directory and survives a reboot. A lock whose recorded
# boot_id is from another boot is stale and must be reclaimed whatever else it holds; a lock
# of the current boot in a partial shape must be left alone, and of several workers racing
# for one stale lock at most one may start the daemon.
set -eu

ROOT=$(unset CDPATH; cd -- "$(dirname -- "$0")/.." && pwd)
SERVICE="$ROOT/module/service.sh"
POST_FS_DATA="$ROOT/module/post-fs-data.sh"
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
  cp "$POST_FS_DATA" "$dir/post-fs-data.sh"
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

# --- post-fs-data.sh (once per boot, before service.sh) drops leftovers of earlier boots that
# carry no complete boot_id; the worker then starts the daemon ---
run_boot() {
  sh "$TMP/$1/post-fs-data.sh" || fail "$1: post-fs-data.sh failed"
  run_worker "$1"
}

setup_case boot-empty-lock
run_boot boot-empty-lock
expect_reclaimed boot-empty-lock

setup_case boot-zero-length-pid
: > "$TMP/boot-zero-length-pid/.service.lock/pid"
run_boot boot-zero-length-pid
expect_reclaimed boot-zero-length-pid

setup_case boot-pid-starttime-no-boot-id
printf '%s\n' "$DEAD_PID" > "$TMP/boot-pid-starttime-no-boot-id/.service.lock/pid"
printf '1\n' > "$TMP/boot-pid-starttime-no-boot-id/.service.lock/starttime"
run_boot boot-pid-starttime-no-boot-id
expect_reclaimed boot-pid-starttime-no-boot-id

setup_case boot-short-boot-id
printf '%s\n' "$DEAD_PID" > "$TMP/boot-short-boot-id/.service.lock/pid"
printf '0000\n' > "$TMP/boot-short-boot-id/.service.lock/boot_id"
run_boot boot-short-boot-id
expect_reclaimed boot-short-boot-id

# a lock that records the current boot (a rerun on a running system) is left alone
setup_case boot-current-lock
printf '%s\n' "$DEAD_PID" > "$TMP/boot-current-lock/.service.lock/pid"
printf '%s\n' "$CURRENT_BOOT" > "$TMP/boot-current-lock/.service.lock/boot_id"
sh "$TMP/boot-current-lock/post-fs-data.sh" || fail "boot-current-lock: post-fs-data.sh failed"
[ -f "$TMP/boot-current-lock/.service.lock/pid" ] || fail "boot-current-lock: lock of the current boot was removed"

# run as `sh post-fs-data.sh` from the module dir ($0 without a slash): MODDIR is still that dir
setup_case boot-bare-name
printf '%s\n' "$DEAD_PID" > "$TMP/boot-bare-name/.service.lock/pid"
printf '%s\n' "$OLD_BOOT" > "$TMP/boot-bare-name/.service.lock/boot_id"
(cd "$TMP/boot-bare-name" && sh post-fs-data.sh) || fail "boot-bare-name: post-fs-data.sh failed"
[ ! -e "$TMP/boot-bare-name/.service.lock" ] || fail "boot-bare-name: lock of a previous boot kept when run by bare name"

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

echo 'PASS: previous-boot locks reclaimed (also by post-fs-data), current-boot partial locks untouched, one winner per stale lock'
