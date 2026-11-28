#!/bin/sh
# .forgejo/module-ci.sh release: the published versionCode must be above the live feed (update.json
# on main's tip, which may be past BASE_SHA) and above every published release, or the updater never
# offers it; an unreadable feed or release list stops the release before the draft is created.
# Real: the whole release mode up to the draft request. Stubbed: curl (fake forge API, the draft POST
# fails so nothing goes further). The repository is a local bare repo reached over file://.
set -u

ROOT=$(unset CDPATH; cd -- "$(dirname -- "$0")/.." && pwd)
for c in bash python3 git unzip; do
  if ! command -v "$c" >/dev/null 2>&1; then
    echo "SKIP: release versionCode ($c not installed)"
    exit 0
  fi
done
TMP=${TMPDIR:-/tmp}/tsoss-release-version-test.$$
trap 'rm -rf "$TMP"' EXIT HUP INT TERM
mkdir -p "$TMP/bin"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

# fake curl: logs "METHOD URL"; the release list answers $LIST_FILE (LIST_FILE=fail: HTTP error),
# -w http_code answers 404, POST bodies go to $POST_LOG and fail; anything else fails
cat > "$TMP/bin/curl" <<'EOF'
#!/bin/sh
m=GET; p=; d=; w=; u=
for a in "$@"; do
  case "$p" in -X) m=$a ;; -d) d=$a ;; -w) w=$a ;; esac
  p=$a; u=$a
done
echo "$m $u" >> "$CALL_LOG"
[ -n "$w" ] && { printf '404'; exit 0; }
case "$m $u" in
  "GET "*"/releases?limit=50")
    [ "$LIST_FILE" = fail ] && exit 22
    cat "$LIST_FILE" ;;
  "POST "*) printf '%s' "$d" > "$POST_LOG"; exit 22 ;;
  *) exit 22 ;;
esac
EOF
chmod 755 "$TMP/bin/curl"
[ "$(PATH="$TMP/bin:$PATH" command -v curl)" = "$TMP/bin/curl" ] || fail "curl stub not first on PATH"

# setup <case> <update.json at BASE_SHA or -> <update.json in a later main commit or -> <release list JSON or fail>
setup() {
  c=$TMP/$1
  mkdir -p "$c/seed/.forgejo" "$c/forge/owner" "$c/work/.ci-out" "$c/run"
  printf 'ZIP_PREFIX=mod\nVERSION_CODE_OFFSET=2\n' > "$c/seed/.forgejo/module-ci.conf"
  [ "$2" = - ] || printf '%s\n' "$2" > "$c/seed/.forgejo/update.json"
  git init -q "$c/seed" && git -C "$c/seed" add -A &&
    git -C "$c/seed" -c user.name=t -c user.email=t@example.invalid commit -qm base || fail "$1: seed repo"
  base=$(git -C "$c/seed" rev-parse HEAD)
  if [ "$3" != - ]; then
    printf '%s\n' "$3" > "$c/seed/.forgejo/update.json"
    git -C "$c/seed" add -A && git -C "$c/seed" -c user.name=t -c user.email=t@example.invalid commit -qm later ||
      fail "$1: later commit"
  fi
  git init -q --bare "$c/forge/owner/mod.git" && git -C "$c/seed" push -q "$c/forge/owner/mod.git" HEAD:refs/heads/main ||
    fail "$1: fake forge"
  if [ "$4" = fail ]; then list=fail; else list=$c/releases.json; printf '%s\n' "$4" > "$list"; fi
  printf '%s\n\n' "$base" > "$c/work/.ci-out/src"
  echo 'fork main' > "$c/work/.ci-out/desc"
  python3 -I -c 'import sys, zipfile
z = zipfile.ZipFile(sys.argv[1], "w")
z.writestr("module.prop", "id=mod\nversion=v1.0 (100-abc-release)\nversionCode=100\n")
z.writestr("service.sh", "true\n")
z.close()' "$c/work/.ci-out/module.zip"
}

# release <case>: runs release mode; sets rc and vc (versionCode in the draft body, empty if none)
release() {
  c=$TMP/$1
  : > "$c/calls"
  rm -f "$c/post"
  (cd "$c/run" && env PATH="$TMP/bin:$PATH" CALL_LOG="$c/calls" POST_LOG="$c/post" LIST_FILE="$list" \
    SERVER_URL="file://$c/forge" REPOSITORY=owner/mod BASE_SHA="$base" RUN_NUMBER=7 \
    RELEASE_TOKEN="$(printf 'fake-%s' "$$")" TMPDIR="$c" \
    bash "$ROOT/.forgejo/module-ci.sh" release "$c/work") > "$c/log" 2>&1
  rc=$?
  vc=
  [ -f "$c/post" ] && vc=$(python3 -I -c 'import json, re, sys
b = json.load(open(sys.argv[1]))["body"]
print(re.search(r"^versionCode (\d+)$", b, re.M).group(1))' "$c/post")
}

# expect_vc <case> <versionCode>: the draft request and the rewritten zip carry it
expect_vc() {
  [ "$vc" = "$2" ] || fail "$1: draft versionCode '$vc', expected $2 ($(tail -n 3 "$TMP/$1/log" | tr '\n' ' '))"
  zvc=$(unzip -p "$TMP/$1/run/rel/mod-v1.0-100-abc-release-ci7.zip" module.prop | sed -n 's/^versionCode=//p')
  [ "$zvc" = "$2" ] || fail "$1: zip module.prop versionCode '$zvc', expected $2"
}

# expect_stopped <case> <log text>: failed before any draft request
expect_stopped() {
  [ "$rc" -ne 0 ] || fail "$1: exit 0"
  ! grep -q '^POST ' "$TMP/$1/calls" || fail "$1: draft requested ($(tr '\n' ';' < "$TMP/$1/calls"))"
  grep -q "$2" "$TMP/$1/log" || fail "$1: '$2' not logged ($(tail -n 2 "$TMP/$1/log" | tr '\n' ' '))"
}

feed() { printf '{"version": "v0.9", "versionCode": %s, "zipUrl": "https://forge.invalid/z.zip", "changelog": ""}' "$1"; }
rel() { printf '{"id": %s, "draft": %s, "body": "Built by module-release.\\nversionCode %s\\nsha256 0"}' "$1" "$2" "$3"; }

# built 100 + offset 2 = 102 is above the feed and every release: unchanged
setup normal "$(feed 50)" - "[$(rel 4 false 60)]"; release normal; expect_vc normal 102

# the feed already holds 102: one above it
setup feed-equal "$(feed 102)" - '[]'; release feed-equal; expect_vc feed-equal 103

# highest published release (not the newest one, drafts ignored) is above the feed
setup list-max "$(feed 102)" - "[$(rel 9 true 500), $(rel 8 false 104), $(rel 5 false 110), {\"id\": 3, \"draft\": false, \"body\": null}]"
release list-max; expect_vc list-max 111

# main moved past BASE_SHA: its tip's feed counts, not the dispatched commit's
setup tip "$(feed 50)" "$(feed 120)" '[]'; release tip; expect_vc tip 121

# no feed yet and no releases: built + offset
setup first - - '[]'; release first; expect_vc first 102

# a feed whose versionCode is not an integer, or not JSON, stops the release
setup feed-string "$(feed '"abc"')" - '[]'; release feed-string; expect_stopped feed-string 'has no readable versionCode'
setup feed-bool "$(feed true)" - '[]'; release feed-bool; expect_stopped feed-bool 'has no readable versionCode'
setup feed-garbage 'not json' - '[]'; release feed-garbage; expect_stopped feed-garbage 'has no readable versionCode'

# an unreadable release list stops the release
setup list-fail "$(feed 50)" - fail; release list-fail; expect_stopped list-fail 'cannot read the published releases'
setup list-object "$(feed 50)" - '{"message": "not a list"}'; release list-object; expect_stopped list-object 'cannot read the published releases'

echo 'PASS: release versionCode above the live feed (main tip) and every published release; unreadable values stop the release'
