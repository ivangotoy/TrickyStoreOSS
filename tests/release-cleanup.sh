#!/bin/sh
# .forgejo/module-ci.sh release: cleanup() deletes only a release the forge still reports as a draft.
# The publish PATCH may be applied by the forge while its reply is lost; deleting on "PUBLISHED != 1"
# alone then removes a published release. Real: log/die/jget/api/cleanup and the publish statements
# (REQ= .. PUBLISHED=1) cut from module-ci.sh; stubbed: curl (fake forge at https://forge.invalid).
set -u

ROOT=$(unset CDPATH; cd -- "$(dirname -- "$0")/.." && pwd)
CI_SCRIPT="$ROOT/.forgejo/module-ci.sh"
if ! command -v bash >/dev/null 2>&1 || ! command -v python3 >/dev/null 2>&1; then
  echo 'SKIP: release cleanup (bash or python3 not installed)'
  exit 0
fi
TMP=${TMPDIR:-/tmp}/tsoss-release-cleanup-test.$$
trap 'rm -rf "$TMP"' EXIT HUP INT TERM
mkdir -p "$TMP/bin"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

{
  echo 'set -euo pipefail'
  echo 'API=https://forge.invalid/api/v1/repos/example/mod RELEASE_ID=7 PUBLISHED=0 SRC_SHA=0123456789abcdef0123456789abcdef01234567'
  echo 'AUTH_DIR=$(mktemp -d) AUTH_H=$AUTH_DIR/header; : > "$AUTH_H"'
  sed -n '/^log() {/p; /^die() {/p; /^jget() {/,/^print(d)/p; /^api() {/,/^}/p; /^cleanup() {/,/^}/p' "$CI_SCRIPT"
  echo 'trap cleanup EXIT'
  echo 'if [ "$1" = publish ]; then'
  sed -n '/^REQ="\$(python3 -I -c .import json,sys;print(json.dumps({"draft":False/,/^PUBLISHED=1$/p' "$CI_SCRIPT"
  echo 'else die "upload failed"; fi'
} > "$TMP/rel.sh"
grep -q '^PUBLISHED=1$' "$TMP/rel.sh" && grep -q '^cleanup() {' "$TMP/rel.sh" && grep -q '^api() {' "$TMP/rel.sh" ||
  fail "cleanup()/api()/publish statements not found in module-ci.sh"

# fake curl: logs "METHOD URL"; PATCH exits $PATCH_RC; GET of the release answers draft=$DRAFT or fails (DRAFT=fail)
cat > "$TMP/bin/curl" <<EOF
#!/bin/sh
m=GET; p=; for a in "\$@"; do [ "\$p" = -X ] && m=\$a; p=\$a; u=\$a; done
echo "\$m \$u" >> "$TMP/calls"
case "\$m" in
  PATCH) exit "\${PATCH_RC:-0}" ;;
  GET) [ "\$DRAFT" = fail ] && exit 22; printf '{"id": 7, "draft": %s}' "\$DRAFT" ;;
esac
EOF
chmod 755 "$TMP/bin/curl"

rel() {
  mode=$1; shift
  : > "$TMP/calls"
  env PATH="$TMP/bin:$PATH" TMPDIR="$TMP" "$@" bash "$TMP/rel.sh" "$mode" > "$TMP/err" 2>&1
}
calls() { tr '\n' ';' < "$TMP/calls"; }

rel publish PATCH_RC=28 DRAFT=false; rc=$?
[ "$rc" -ne 0 ] || fail "failed PATCH, forge reports published: exit 0"
grep -q '^PATCH ' "$TMP/calls" || fail "failed PATCH, forge reports published: no PATCH sent"
! grep -q '^DELETE ' "$TMP/calls" || fail "failed PATCH, forge reports published: release deleted ($(calls))"

rel upload DRAFT=true; rc=$?
[ "$rc" -ne 0 ] || fail "failure before publish: exit 0"
grep -qx 'DELETE https://forge.invalid/api/v1/repos/example/mod/releases/7' "$TMP/calls" ||
  fail "failure before publish: draft not deleted ($(calls))"

rel publish PATCH_RC=28 DRAFT=fail; rc=$?
[ "$rc" -ne 0 ] || fail "failed PATCH, unreadable state: exit 0"
! grep -q '^DELETE ' "$TMP/calls" || fail "failed PATCH, unreadable state: release deleted ($(calls))"
grep -q 'release 7' "$TMP/err" || fail "failed PATCH, unreadable state: release id not logged"

rel publish DRAFT=false; rc=$?
[ "$rc" -eq 0 ] || fail "good publish: exit $rc"
! grep -q '^DELETE ' "$TMP/calls" || fail "good publish: release deleted ($(calls))"

echo 'PASS: release cleanup keeps a published or unknown release, deletes a confirmed draft'
