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

# The real build() of .forgejo/module-ci.conf (no upstream merge here: UPSTREAM_URL cleared) runs
# tests/run.sh before Gradle, with its TMPDIR under the build user's HOME. The fixture's suite
# records its TMPDIR and passes or fails; the gradlew stub refuses to run unless that record is
# there, then leaves a release zip in out/.
for kind in suite-ok suite-failed; do
  w="$TMP/$kind"
  mkdir -p "$w/.forgejo" "$w/tests"
  cp "$ROOT/.forgejo/module-ci.sh" "$ROOT/.forgejo/module-ci.conf" "$w/.forgejo/"
  printf '\nUPSTREAM_URL=""\n' >> "$w/.forgejo/module-ci.conf"
  rc_suite=0
  [ "$kind" = suite-failed ] && rc_suite=1
  printf '#!/bin/sh\nprintf "%%s\\n" "$TMPDIR" > "$HOME/suite-tmpdir"\necho "stub suite rc=%s" >&2\nexit %s\n' \
    "$rc_suite" "$rc_suite" > "$w/tests/run.sh"
  cat > "$w/gradlew" <<'EOF'
#!/bin/sh
echo "$*" > "$HOME/gradle-ran"
read -r t < "$HOME/suite-tmpdir" || exit 3
case "$t" in "$HOME"/*) ;; *) exit 4 ;; esac
mkdir -p out && echo zip > out/stub-Release.zip
EOF
  (cd "$w" && git init -q && git add -A && git -c user.name=t -c user.email=t@example.invalid commit -qm t) > /dev/null 2>&1 ||
    fail "$kind: fixture repo"
  : > "$w/setpriv.log"
  rc=0
  (cd "$w" && env PATH="$TMP/bin:$PATH" SETPRIV_LOG="$w/setpriv.log" SERVER_URL=https://forge.invalid \
    REPOSITORY=owner/repo BASE_SHA="$(git rev-parse HEAD)" bash .forgejo/module-ci.sh build "$w") > "$w/out.log" 2>&1 || rc=$?
  grep -q "stub suite rc=$rc_suite" "$w/out.log" || fail "$kind: tests/run.sh did not run ($(tail -n 2 "$w/out.log" | tr '\n' ' '))"
  case "$(cat "$w/.ci-home/suite-tmpdir" 2>/dev/null)" in
    "$w/.ci-home"/*) ;;
    *) fail "$kind: suite TMPDIR not under the build user's HOME: '$(cat "$w/.ci-home/suite-tmpdir" 2>/dev/null)'" ;;
  esac
  if [ "$kind" = suite-ok ]; then
    [ "$rc" -eq 0 ] && [ -f "$w/.ci-out/module.zip" ] || fail "passing suite: build rc=$rc, $(tail -n 2 "$w/out.log" | tr '\n' ' ')"
    [ -f "$w/.ci-home/gradle-ran" ] || fail "passing suite: Gradle did not run"
  else
    [ "$rc" -ne 0 ] || fail "failing suite: build exit 0"
    [ ! -e "$w/.ci-home/gradle-ran" ] || fail "failing suite: Gradle ran after the suite failed"
    [ ! -e "$w/.ci-out/module.zip" ] || fail "failing suite: a module zip was left"
  fi
  grep -q 'kill-requested .*--reuid=1000 .*kill -9 -1' "$w/setpriv.log" || fail "$kind build: build user's processes not killed"
done

echo "PASS: build step kills the build user's processes after a passing and a failing build; build() runs the suite before Gradle"
