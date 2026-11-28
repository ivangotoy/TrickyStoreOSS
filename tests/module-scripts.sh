#!/bin/sh
# Runs the real module scripts (customize.sh, daemon, post-fs-data.sh,
# update-binary) against a fake module root and PATH stubs. Absolute device
# paths are rewritten into the fake root in a copy of each script.
set -eu

ROOT=$(unset CDPATH; cd -- "$(dirname -- "$0")/.." && pwd)
MODULE="$ROOT/module"
TMP=${TMPDIR:-/tmp}/tsoss-module-test.$$
trap 'rm -rf "$TMP"' EXIT HUP INT TERM
mkdir -p "$TMP"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

# copy_rewritten <script> <dest> <fake root>: copy with /data/adb and
# /system/bin/app_process pointed into the fake root.
copy_rewritten() {
  sed -e "s|/data/adb|$3/data/adb|g" -e "s|/system/bin/app_process|$3/system/bin/app_process|g" "$1" > "$2"
  if sed -e "s|$3/data/adb||g" -e "s|$3/system/bin/app_process||g" "$2" | grep -q -e /data/adb -e /system/bin/app_process; then
    fail "device path left in rewritten copy of $1"
  fi
}

make_stubs() {
  mkdir -p "$1"
  cat > "$1/unzip" <<'STUB'
#!/bin/sh
# Fake unzip over a directory that stands in for the module zip.
printf '%s\n' "$*" >> "$STUB_LOG"
case "$1" in
  -l)
    (cd "$2" && find . -type f | sed 's|^\./||')
    ;;
  -qqjo)
    [ "$4" = -d ] || exit 9
    [ -f "$2/$3" ] || exit 11
    mkdir -p "$5"
    cp "$2/$3" "$5/${3##*/}"
    ;;
  *)
    exit 10
    ;;
esac
STUB
  cat > "$1/mount" <<'STUB'
#!/bin/sh
exit 0
STUB
  chmod +x "$1/unzip" "$1/mount"
}

make_zip() {
  zip=$1
  mkdir -p "$zip/lib/arm64-v8a" "$zip/lib/x86_64"
  for f in customize.sh module.prop post-fs-data.sh service.sh sepolicy.rule daemon keybox.xml target.txt; do
    cp "$MODULE/$f" "$zip/$f"
  done
  echo 'synthetic dex' > "$zip/classes.dex"
  for abi in arm64-v8a x86_64; do
    echo "synthetic $abi lib" > "$zip/lib/$abi/libTrickyStoreOSS.so"
    echo "synthetic $abi inject" > "$zip/lib/$abi/libinject.so"
  done
}

# run_customize <case> [VAR=value ...]: runs customize.sh the way the
# Magisk/KernelSU installer sources it; prints the exit status.
run_customize() {
  name=$1
  shift
  case_dir="$TMP/$name"
  fake="$case_dir/root"
  mkdir -p "$case_dir/modpath" "$case_dir/installer" "$fake/data/adb/modules"
  [ -d "$case_dir/zip" ] || make_zip "$case_dir/zip"
  make_stubs "$case_dir/bin"
  cp "$case_dir/zip/module.prop" "$case_dir/installer/module.prop"
  copy_rewritten "$MODULE/customize.sh" "$case_dir/customize.sh" "$fake"
  cat > "$case_dir/installer.sh" <<'RUNNER'
ui_print() { echo "$1"; }
abort() { echo "$1"; exit 1; }
grep_prop() { sed -n "s/^$1=//p" "$2" | head -n 1; }
. "$CASE_DIR/customize.sh"
RUNNER
  : > "$case_dir/unzip.log"
  set +e
  env PATH="$case_dir/bin:$PATH" STUB_LOG="$case_dir/unzip.log" CASE_DIR="$case_dir" \
    TMPDIR="$case_dir/installer" ZIPFILE="$case_dir/zip" MODPATH="$case_dir/modpath" \
    BOOTMODE=true KSU=false ARCH=arm64 API=34 "$@" sh "$case_dir/installer.sh" > "$case_dir/log" 2>&1
  status=$?
  set -e
  echo "$status"
}

case_log() { cat "$TMP/$1/log"; }

# --- customize.sh: refusals before anything is written ---
status=$(run_customize recovery BOOTMODE=false)
[ "$status" -ne 0 ] || fail "recovery install should abort"
grep -q 'Install from recovery is NOT supported' "$TMP/recovery/log" || fail "recovery abort message missing"
[ ! -e "$TMP/recovery/root/data/adb/tricky_store" ] || fail "recovery abort created the config dir"

status=$(run_customize oldksu KSU=true KSU_VER_CODE=10000)
[ "$status" -ne 0 ] || fail "old KernelSU should abort"
grep -q 'Please update your KernelSU' "$TMP/oldksu/log" || fail "old KernelSU message missing"

status=$(run_customize badarch ARCH=mips)
[ "$status" -ne 0 ] || fail "unsupported arch should abort"
grep -q 'Unsupported architecture: mips' "$TMP/badarch/log" || fail "unsupported arch message missing"

status=$(run_customize oldsdk API=28)
[ "$status" -ne 0 ] || fail "SDK 28 should abort"
grep -q 'Unsupported SDK: 28' "$TMP/oldsdk/log" || fail "old SDK message missing"

# --- customize.sh: fresh install ---
status=$(run_customize fresh KSU=true KSU_VER_CODE=12000)
[ "$status" -eq 0 ] || { case_log fresh; fail "fresh install failed"; }
mp="$TMP/fresh/modpath"
for f in customize.sh module.prop post-fs-data.sh service.sh sepolicy.rule daemon classes.dex libTrickyStoreOSS.so inject; do
  [ -f "$mp/$f" ] || fail "fresh install missing $f"
done
[ ! -e "$mp/libinject.so" ] || fail "libinject.so was not renamed to inject"
[ -x "$mp/daemon" ] || fail "daemon not executable"
[ -x "$mp/inject" ] || fail "inject not executable"
grep -q 'synthetic arm64-v8a lib' "$mp/libTrickyStoreOSS.so" || fail "wrong ABI library installed"
cfg="$TMP/fresh/root/data/adb/tricky_store"
cmp -s "$cfg/keybox.xml" "$MODULE/keybox.xml" || fail "default keybox not installed"
cmp -s "$cfg/target.txt" "$MODULE/target.txt" || fail "default target.txt not installed"
grep -q "Installing Tricky Store OSS REPLACEMEVER" "$TMP/fresh/log" || fail "version line missing"
[ "$(stat -c %a "$cfg")" = 700 ] || fail "config dir is not 0700"
[ "$(stat -c %a "$cfg/keybox.xml")" = 600 ] || fail "keybox.xml is not 0600"
[ "$(stat -c %a "$cfg/target.txt")" = 600 ] || fail "target.txt is not 0600"

# --- customize.sh: x64 picks the x86_64 libraries ---
status=$(run_customize x64 ARCH=x64)
[ "$status" -eq 0 ] || { case_log x64; fail "x64 install failed"; }
grep -q 'synthetic x86_64 lib' "$TMP/x64/modpath/libTrickyStoreOSS.so" || fail "x64 did not use x86_64 library"

# --- customize.sh: existing user config is preserved ---
mkdir -p "$TMP/keep/root/data/adb/tricky_store"
echo '<synthetic-user-keybox/>' > "$TMP/keep/root/data/adb/tricky_store/keybox.xml"
echo 'com.example.synthetic' > "$TMP/keep/root/data/adb/tricky_store/target.txt"
echo 'all=2020-01-01' > "$TMP/keep/root/data/adb/tricky_store/security_patch.txt"
chmod 0755 "$TMP/keep/root/data/adb/tricky_store"
chmod 0644 "$TMP/keep/root/data/adb/tricky_store/keybox.xml" "$TMP/keep/root/data/adb/tricky_store/security_patch.txt"
status=$(run_customize keep)
[ "$status" -eq 0 ] || { case_log keep; fail "upgrade install failed"; }
grep -qx '<synthetic-user-keybox/>' "$TMP/keep/root/data/adb/tricky_store/keybox.xml" || fail "user keybox overwritten"
grep -qx 'com.example.synthetic' "$TMP/keep/root/data/adb/tricky_store/target.txt" || fail "user target.txt overwritten"
[ "$(stat -c %a "$TMP/keep/root/data/adb/tricky_store")" = 700 ] || fail "upgrade left config dir open"
[ "$(stat -c %a "$TMP/keep/root/data/adb/tricky_store/keybox.xml")" = 600 ] || fail "upgrade left keybox.xml readable"
[ "$(stat -c %a "$TMP/keep/root/data/adb/tricky_store/security_patch.txt")" = 600 ] || fail "upgrade left security_patch.txt readable"

# --- customize.sh: conflicting modules are flagged for removal ---
mkdir -p "$TMP/conflict/root/data/adb/modules/teesim" "$TMP/conflict/root/data/adb/modules/oh_my_keymint"
echo 'name=Synthetic TEE module' > "$TMP/conflict/root/data/adb/modules/teesim/module.prop"
echo 'name=Synthetic keymint module' > "$TMP/conflict/root/data/adb/modules/oh_my_keymint/module.prop"
status=$(run_customize conflict)
[ "$status" -eq 0 ] || { case_log conflict; fail "install with conflicting modules failed"; }
[ -e "$TMP/conflict/root/data/adb/modules/teesim/remove" ] || fail "teesim not flagged for removal"
[ -e "$TMP/conflict/root/data/adb/modules/oh_my_keymint/remove" ] || fail "oh_my_keymint not flagged for removal"
grep -q 'Synthetic TEE module module will be removed' "$TMP/conflict/log" || fail "removal notice missing"

# --- customize.sh: service.apk is used when classes.dex is absent ---
mkdir -p "$TMP/apk"
make_zip "$TMP/apk/zip"
rm "$TMP/apk/zip/classes.dex"
echo 'synthetic apk' > "$TMP/apk/zip/service.apk"
status=$(run_customize apk)
[ "$status" -eq 0 ] || { case_log apk; fail "service.apk install failed"; }
[ -f "$TMP/apk/modpath/service.apk" ] || fail "service.apk not installed"

# --- customize.sh: missing payloads abort ---
mkdir -p "$TMP/nodex"
make_zip "$TMP/nodex/zip"
rm "$TMP/nodex/zip/classes.dex"
status=$(run_customize nodex)
[ "$status" -ne 0 ] || fail "zip without dex/apk should abort"
grep -q 'Neither service.apk nor classes.dex found' "$TMP/nodex/log" || fail "missing dex message missing"

mkdir -p "$TMP/nolib"
make_zip "$TMP/nolib/zip"
rm "$TMP/nolib/zip/lib/arm64-v8a/libinject.so"
status=$(run_customize nolib)
[ "$status" -ne 0 ] || fail "zip without injector should abort"
grep -q 'Failed to extract lib/arm64-v8a/libinject.so' "$TMP/nolib/log" || fail "missing lib message missing"

# --- daemon: classpath selection and app_process arguments ---
run_daemon() {
  name=$1
  dir="$TMP/$name"
  mkdir -p "$dir/mod" "$dir/root/system/bin"
  copy_rewritten "$MODULE/daemon" "$dir/daemon" "$dir/root"
  cat > "$dir/root/system/bin/app_process" <<'STUB'
#!/bin/sh
printf '%s\n' "$@" > "$APP_PROCESS_LOG"
STUB
  chmod +x "$dir/root/system/bin/app_process"
  set +e
  APP_PROCESS_LOG="$dir/app_process.args" sh "$dir/daemon" "$dir/mod" > "$dir/log" 2>&1
  status=$?
  set -e
  echo "$status"
}

mkdir -p "$TMP/daemon-none"
status=$(run_daemon daemon-none)
[ "$status" -eq 1 ] || fail "daemon without dex/apk should exit 1"
grep -q 'Neither classes.dex nor service.apk found' "$TMP/daemon-none/log" || fail "daemon error message missing"
[ ! -e "$TMP/daemon-none/app_process.args" ] || fail "daemon started app_process without a classpath"

mkdir -p "$TMP/daemon-dex/mod"
: > "$TMP/daemon-dex/mod/classes.dex"
: > "$TMP/daemon-dex/mod/service.apk"
status=$(run_daemon daemon-dex)
[ "$status" -eq 0 ] || fail "daemon with classes.dex failed"
expected=$(printf '%s\n' "-Djava.class.path=$TMP/daemon-dex/mod/classes.dex" "$TMP/daemon-dex/mod" \
  --nice-name=TrickyStoreOSS io.github.beakthoven.TrickyStoreOSS.MainKt)
[ "$(cat "$TMP/daemon-dex/app_process.args")" = "$expected" ] || fail "daemon app_process arguments changed"

mkdir -p "$TMP/daemon-apk/mod"
: > "$TMP/daemon-apk/mod/service.apk"
status=$(run_daemon daemon-apk)
[ "$status" -eq 0 ] || fail "daemon with service.apk failed"
grep -qx -- "-Djava.class.path=$TMP/daemon-apk/mod/service.apk" "$TMP/daemon-apk/app_process.args" ||
  fail "daemon did not fall back to service.apk"

# --- post-fs-data.sh: must succeed without a supervisor lock (a copy: its MODDIR is the
# script's own directory, so the source tree's module/ is never touched) ---
mkdir -p "$TMP/post-fs-data"
cp "$MODULE/post-fs-data.sh" "$TMP/post-fs-data/post-fs-data.sh"
sh "$TMP/post-fs-data/post-fs-data.sh" || fail "post-fs-data.sh failed"

# --- update-binary: refuses without Magisk, hands over to install_module ---
run_update_binary() {
  name=$1
  ver=$2
  dir="$TMP/$name"
  mkdir -p "$dir/root/data/adb/magisk"
  make_stubs "$dir/bin"
  copy_rewritten "$MODULE/META-INF/com/google/android/update-binary" "$dir/update-binary" "$dir/root"
  if [ -n "$ver" ]; then
    cat > "$dir/root/data/adb/magisk/util_functions.sh" <<EOF
MAGISK_VER_CODE=$ver
install_module() { echo "install_module zip=\$ZIPFILE"; }
EOF
  fi
  set +e
  PATH="$dir/bin:$PATH" STUB_LOG="$dir/unzip.log" sh "$dir/update-binary" 3 1 "$dir/synthetic.zip" > "$dir/log" 2>&1
  status=$?
  set -e
  echo "$status"
}

status=$(run_update_binary ub-none '')
[ "$status" -eq 1 ] || fail "update-binary without Magisk should exit 1"
grep -q 'Please install Magisk v20.4+' "$TMP/ub-none/log" || fail "update-binary Magisk message missing"

status=$(run_update_binary ub-old 20000)
[ "$status" -eq 1 ] || fail "update-binary with old Magisk should exit 1"

status=$(run_update_binary ub-ok 20400)
[ "$status" -eq 0 ] || fail "update-binary with Magisk 20400 failed"
grep -q "install_module zip=$TMP/ub-ok/synthetic.zip" "$TMP/ub-ok/log" || fail "install_module not called with the zip"

echo 'PASS: customize refusals/fresh/x64/upgrade/conflicts/apk/missing payloads/config modes, daemon classpath, post-fs-data, update-binary'
