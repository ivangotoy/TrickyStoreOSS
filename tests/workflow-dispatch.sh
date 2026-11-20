#!/bin/sh
# .forgejo/workflows/module-release.yml: the job builds the dispatched commit even when main has
# moved since. The steps whose run text clones or calls `module-ci.sh build` run against a local
# bare repo whose main has a commit after BASE_SHA. The fixture's .forgejo/module-ci.sh is a marker
# script that records which commit's copy ran; the real pipeline is never reachable from here.
# Run blocks are read without PyYAML.
set -u

ROOT=$(unset CDPATH; cd -- "$(dirname -- "$0")/.." && pwd)
if ! command -v python3 >/dev/null 2>&1 || ! command -v git >/dev/null 2>&1; then
  echo 'SKIP: workflow dispatched commit (python3 or git not installed)'
  exit 0
fi
TMP=${TMPDIR:-/tmp}/tsoss-workflow-dispatch-test.$$
trap 'rm -rf "$TMP"' EXIT HUP INT TERM
mkdir -p "$TMP"

wf_dispatched() {
  _wf=$TMP/workflow
  mkdir -p "$_wf/job" "$_wf/forge/owner" "$_wf/seed/.forgejo" || return 1
  git init -q --bare "$_wf/forge/owner/repo.git" && git init -q "$_wf/seed" || return 1
  for _c in dispatched later-on-main; do
    printf '#!/bin/sh\necho "%s $*" >> "$MARKER_LOG"\n' "$_c" > "$_wf/seed/.forgejo/module-ci.sh"
    (cd "$_wf/seed" && git add -A && git -c user.name=t -c user.email=t@example.invalid commit -qm "$_c") || return 1
    [ "$_c" = dispatched ] && _base=$(git -C "$_wf/seed" rev-parse HEAD)
  done
  git -C "$_wf/seed" push -q "$_wf/forge/owner/repo.git" HEAD:refs/heads/main || return 1
  python3 -I - "$ROOT/.forgejo/workflows/module-release.yml" > "$_wf/steps.sh" <<'PY'
import re, sys
steps, cur = [], None
for l in open(sys.argv[1]).read().split("\n"):
    if re.match(r"^      - name:", l):
        cur = {"run": [], "in": False}; steps.append(cur); continue
    if cur is None:
        continue
    if re.match(r"^        run: \|\s*$", l):
        cur["in"] = True; continue
    m = re.match(r"^        run: (.+)$", l)
    if m:
        cur["run"].append(m.group(1)); continue
    if cur["in"]:
        if l.startswith("          ") or not l.strip():
            cur["run"].append(l[10:])
        else:
            cur["in"] = False
for st in steps:
    text = "\n".join(st["run"])
    if "git clone" in text or "module-ci.sh build" in text:
        print("(\n" + text + "\n)")
PY
  : > "$_wf/marker.log"
  (cd "$_wf/job" && env SERVER_URL="file://$_wf/forge" REPOSITORY=owner/repo BASE_SHA="$_base" \
    MARKER_LOG="$_wf/marker.log" sh "$_wf/steps.sh") > "$_wf/out.log" 2>&1 || { tail -n 2 "$_wf/out.log"; return 1; }
  [ "$(git -C "$_wf/job/src" rev-parse HEAD)" = "$_base" ] && [ "$(cat "$_wf/marker.log")" = "dispatched build src" ] \
    || { echo "     ran: $(tr '\n' ';' < "$_wf/marker.log")"; return 1; }
}

wf_dispatched || { echo "FAIL: workflow: checkout and build do not use the dispatched commit after main moved" >&2; exit 1; }
echo 'PASS: workflow: checkout and build use the dispatched commit after main moved'
