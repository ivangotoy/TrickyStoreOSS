MODDIR=${0%/*}
[ "$MODDIR" = "$0" ] && MODDIR=.
MODDIR=$(unset CDPATH; cd -- "$MODDIR" 2>/dev/null && pwd) || exit 0

# post-fs-data runs once per boot, before service.sh. A supervisor lock found here was left by an
# earlier boot (crash or power loss while it was written or reaped) unless it records this boot's
# id, so drop it: a leftover in any shape would otherwise keep the daemon from starting.
LOCKDIR="$MODDIR/.service.lock"
if [ -d "$LOCKDIR" ]; then
  current_boot_id=$(cat /proc/sys/kernel/random/boot_id 2>/dev/null)
  lock_boot_id=$(cat "$LOCKDIR/boot_id" 2>/dev/null)
  if [ -n "$current_boot_id" ] && [ "$lock_boot_id" != "$current_boot_id" ]; then
    rm -rf "$LOCKDIR"
  fi
fi
exit 0
