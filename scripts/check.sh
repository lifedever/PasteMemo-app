#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
MODULE_CACHE_DIR="$ROOT_DIR/.build/ModuleCache"
TEMP_HOME_DIR="$ROOT_DIR/.tmp-home"

usage() {
  cat <<'EOF'
Usage:
  bash ./scripts/check.sh [--all|--staged]

Options:
  --all       Check the whole repository scope
  --staged    Check only staged files
EOF
}

scope="all"
if [[ $# -gt 1 ]]; then
  usage >&2
  exit 1
fi

if [[ $# -eq 1 ]]; then
  case "$1" in
    --all) scope="all" ;;
    --staged) scope="staged" ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      usage >&2
      exit 1
      ;;
  esac
fi

cd "$ROOT_DIR"
mkdir -p "$MODULE_CACHE_DIR" "$TEMP_HOME_DIR"

run_swift_eval() {
  HOME="$TEMP_HOME_DIR" \
  CLANG_MODULE_CACHE_PATH="$MODULE_CACHE_DIR" \
  swift -module-cache-path "$MODULE_CACHE_DIR" "$@"
}

run_swift_build() {
  HOME="$TEMP_HOME_DIR" \
  CLANG_MODULE_CACHE_PATH="$MODULE_CACHE_DIR" \
  swift build --disable-sandbox "$@"
}

collect_files() {
  if [[ "$scope" == "staged" ]]; then
    git rev-parse --git-dir >/dev/null 2>&1 || {
      echo "[check] not a git repository" >&2
      exit 1
    }
    git diff --cached --name-only --diff-filter=ACMR
  else
    git ls-files
  fi
}

files=()
while IFS= read -r line; do
  files+=("$line")
done < <(collect_files)

if [[ ${#files[@]} -eq 0 ]]; then
  echo "[check] no files to inspect"
  exit 0
fi

swift_changed=false
shell_files=()
strings_files=()

for file in "${files[@]}"; do
  case "$file" in
    Package.swift|Sources/*.swift|Sources/**/*.swift|Tests/*.swift|Tests/**/*.swift)
      swift_changed=true
      ;;
  esac

  case "$file" in
    *.sh)
      shell_files+=("$file")
      ;;
    *.strings)
      strings_files+=("$file")
      ;;
  esac
done

run_count=0

if [[ ${#shell_files[@]} -gt 0 ]]; then
  echo "[check] bash syntax"
  for file in "${shell_files[@]}"; do
    bash -n "$file"
  done
  run_count=$((run_count + 1))
fi

if [[ ${#strings_files[@]} -gt 0 ]]; then
  echo "[check] strings lint"
  for file in "${strings_files[@]}"; do
    run_swift_eval -e '
import Foundation
let path = CommandLine.arguments[1]
let text = try String(contentsOfFile: path, encoding: .utf8)
_ = (text as NSString).propertyListFromStringsFileFormat()
' "$file" >/dev/null
  done
  run_count=$((run_count + 1))
fi

if [[ "$swift_changed" == true ]]; then
  echo "[check] swift build"
  run_swift_build
  run_count=$((run_count + 1))
fi

if [[ $run_count -eq 0 ]]; then
  echo "[check] no matching checks for current file set"
else
  echo "[check] done"
fi
