#!/bin/bash
set -euo pipefail
TASK_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TASK_UPSTREAM="${1:-$TASK_ROOT/upstream}"
TASK_COMMIT="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["commit"])' "$TASK_ROOT/upstream.lock.json")"
if [ -e "$TASK_UPSTREAM" ]; then
  echo "Destination already exists; use a fresh directory." >&2
  exit 1
fi
git init "$TASK_UPSTREAM"
git -C "$TASK_UPSTREAM" remote add origin https://github.com/claration/feather.git
git -C "$TASK_UPSTREAM" fetch --depth 1 origin "$TASK_COMMIT"
git -C "$TASK_UPSTREAM" checkout --detach FETCH_HEAD
test "$(git -C "$TASK_UPSTREAM" rev-parse HEAD)" = "$TASK_COMMIT"
git -C "$TASK_UPSTREAM" submodule update --init --recursive
python3 "$TASK_ROOT/scripts/prepare.py" "$TASK_UPSTREAM"
