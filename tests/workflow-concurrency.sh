#!/bin/sh
# .forgejo/workflows/module-release.yml: runs are serialised by a workflow-level concurrency
# group that never cancels a running release (parallel runs would compute the same versionCode).
set -u

ROOT=$(unset CDPATH; cd -- "$(dirname -- "$0")/.." && pwd)
if ! command -v python3 >/dev/null 2>&1 || ! python3 -I -c 'import yaml' 2>/dev/null; then
  echo 'SKIP: workflow concurrency (python3 with PyYAML not installed)'
  exit 0
fi

python3 -I - "$ROOT/.forgejo/workflows/module-release.yml" <<'PY'
import sys, yaml
wf = yaml.safe_load(open(sys.argv[1]))
c = wf.get("concurrency")
if not isinstance(c, dict):
    sys.exit("FAIL: workflow: no workflow-level concurrency mapping")
if not isinstance(c.get("group"), str) or not c["group"].strip():
    sys.exit("FAIL: workflow: concurrency group is empty")
if c.get("cancel-in-progress") is not False:
    sys.exit("FAIL: workflow: concurrency must not cancel a running release")
for name, job in (wf.get("jobs") or {}).items():
    jc = job.get("concurrency")
    if jc is not None and (not isinstance(jc, dict) or jc.get("cancel-in-progress") is not False):
        sys.exit(f"FAIL: workflow: job {name} concurrency may cancel a running release")
print("PASS: workflow: one release at a time, a running release is never cancelled")
PY
