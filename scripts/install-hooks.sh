#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

cd "$ROOT_DIR"

git rev-parse --git-dir >/dev/null 2>&1 || {
  echo "Not a git repository: $ROOT_DIR" >&2
  exit 1
}

git config core.hooksPath .githooks
echo "[hooks] core.hooksPath set to .githooks"
