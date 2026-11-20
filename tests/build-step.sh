#!/bin/sh
# .forgejo/module-ci.sh build: whatever the build user started is killed after the build, failed
# or not. setpriv and chown are stubs: the stub records a kill and never runs it (here the test
# user may well be the build uid, and `kill -9 -1` would end this session).
set -u

ROOT=$(unset CDPATH; cd -- "$(dirname -- "$0")/.." && pwd)
if ! command -v bash >/dev/null 2>&1 || ! command -v git >/dev/null 2>&1; then
  echo 'SKIP: build step (bash or git not installed)'
  exit 0
fi
TMP=${TMPDIR:-/tmp}/tsoss-build-step-test.$$
trap 'rm -rf "$TMP"' EXIT HUP INT TERM
mkdir -p "$TMP/bin"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

cat > "$TMP/bin/setpriv" <<'EOF'
#!/bin/sh
case " $* " in *" kill "*) echo "kill-requested $*" >> "$SETPRIV_LOG"; exit 0 ;; esac
while [ $# -gt 0 ]; do case "$1" in --*) shift ;; *) break ;; esac; done
exec "$@"
EOF
printf '#!/bin/sh\nexit 0\n' > "$TMP/bin/chown"
chmod 755 "$TMP/bin/setpriv" "$TMP/bin/chown"
[ "$(PATH="$TMP/bin:$PATH" command -v setpriv)" = "$TMP/bin/setpriv" ] || fail "setpriv stub not first on PATH, not run"

for kind in ok failed; do
  w="$TMP/$kind"
  mkdir -p "$w/.forgejo"
  cp "$ROOT/.forgejo/module-ci.sh" "$w/.forgejo/"
  if [ "$kind" = ok ]; then
    printf 'build() { echo zip > "$OUT/module.zip"; }\n' > "$w/.forgejo/module-ci.conf"
  else
    printf 'build() { echo "stub build failed" >&2; return 1; }\n' > "$w/.forgejo/module-ci.conf"
  fi
  (cd "$w" && git init -q && git add -A && git -c user.name=t -c user.email=t@example.invalid commit -qm t) > /dev/null 2>&1 ||
    fail "$kind: fixture repo"
  : > "$w/setpriv.log"
  rc=0
  (cd "$w" && env PATH="$TMP/bin:$PATH" SETPRIV_LOG="$w/setpriv.log" SERVER_URL=https://forge.invalid \
    REPOSITORY=owner/repo BASE_SHA="$(git rev-parse HEAD)" bash .forgejo/module-ci.sh build "$w") > "$w/out.log" 2>&1 || rc=$?
  if [ "$kind" = ok ]; then
    [ "$rc" -eq 0 ] && [ -f "$w/.ci-out/module.zip" ] || fail "passing build: rc=$rc, $(tail -n 2 "$w/out.log" | tr '\n' ' ')"
  else
    [ "$rc" -ne 0 ] && grep -q "stub build failed" "$w/out.log" || fail "failing build: rc=$rc, $(tail -n 2 "$w/out.log" | tr '\n' ' ')"
  fi
  ! grep -q "unbound variable" "$w/out.log" || fail "$kind build: unbound variable"
  grep -q 'kill-requested .*--reuid=1000 .*kill -9 -1' "$w/setpriv.log" || fail "$kind build: build user's processes not killed"
done

echo "PASS: build step kills the build user's processes after a passing and a failing build"
