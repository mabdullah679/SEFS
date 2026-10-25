#!/usr/bin/env bash
# Unit proof runner. No AWS calls: mock providers, plus one real-provider local render (efs_policy) behind a network blackhole.
#
#   tests/unit/run.sh [TREE] [SUITE]
#     TREE   repo root to test (default: this repo)
#     SUITE  all (default) | static | main | apply
#
#   static  R4: prevent_destroy = true literally inside aws_efs_file_system
#           (terraform test cannot see lifecycle blocks, so this is a parse).
#   main    terraform test -test-directory=tests/unit, run in TREE as-is.
#   apply   terraform test -test-directory=tests/unit/apply, run in a TEMP
#           COPY of TREE with only the prevent_destroy line stripped from
#           modules/efs (apply-mode mocks cannot tear it down otherwise).
#
# Network guard: every `terraform test` runs with HTTP(S)_PROXY pointed at a
# closed local port, so the one real-provider file (efs_policy) cannot reach
# AWS even by accident. (init runs without it: it needs the registry/cache.)
#
# Exit 0 only if every selected suite ran AND passed. A suite that could not
# run is a failure, never a pass.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TREE="$(cd "${1:-$HERE/../..}" && pwd)"
SUITE="${2:-all}"
TF="${TF:-terraform}"
BLACKHOLE="http://127.0.0.1:9"

tf_test() {
  HTTPS_PROXY="$BLACKHOLE" HTTP_PROXY="$BLACKHOLE" https_proxy="$BLACKHOLE" http_proxy="$BLACKHOLE" \
    NO_PROXY="" no_proxy="" AWS_EC2_METADATA_DISABLED=true \
    "$TF" test -no-color "$@"
}

red()   { printf '\033[31m%s\033[0m\n' "$*"; }
green() { printf '\033[32m%s\033[0m\n' "$*"; }

# Prints the line numbers of `prevent_destroy = true` that sit inside a
# resource "aws_efs_file_system" block (brace-depth tracked, comments ignored).
efs_prevent_destroy_lines() {
  local dir="$1"
  local f
  for f in "$dir"/modules/efs/*.tf; do
    [ -e "$f" ] || continue
    awk -v F="$f" '
      { line = $0; sub(/#.*/, "", line); sub(/\/\/.*/, "", line) }
      !inres && line ~ /^[[:space:]]*resource[[:space:]]+"aws_efs_file_system"[[:space:]]+"/ { inres = 1; depth = 0 }
      inres {
        if (line ~ /prevent_destroy[[:space:]]*=[[:space:]]*true/) print F ":" NR
        n = gsub(/\{/, "{", line); m = gsub(/\}/, "}", line); depth += n - m
        if (depth <= 0 && (n + m) > 0) inres = 0
      }' "$f"
  done
}

suite_static() {
  local hits
  hits="$(efs_prevent_destroy_lines "$TREE")"
  if [ -n "$hits" ]; then
    green "PASS r04_prevent_destroy_static  ($hits)"
    return 0
  fi
  if ! ls "$TREE"/modules/efs/*.tf >/dev/null 2>&1; then
    red "FAIL r04_prevent_destroy_static  (no modules/efs/*.tf found: check could not run)"
  else
    red "FAIL r04_prevent_destroy_static  (no prevent_destroy = true inside resource \"aws_efs_file_system\")"
  fi
  return 1
}

tf_init() {
  # Test-file `module { source }` blocks are only installed when init is told
# about the test directory.
  (cd "$1" && "$TF" init -backend=false -input=false -no-color -test-directory="$2" >/dev/null) || {
    red "FAIL terraform init in $1 (suite could not run)"
    return 1
  }
}

suite_main() {
  tf_init "$TREE" tests/unit || return 1
  (cd "$TREE" && tf_test -test-directory=tests/unit)
}

suite_apply() {
  local tmp rc
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/sefs-unit-apply.XXXXXX")"
  rsync -a --exclude .git "$TREE"/ "$tmp"/
  local f
  for f in "$tmp"/modules/efs/*.tf; do
    [ -e "$f" ] || continue
    sed -i.bak -E 's/^([[:space:]]*)prevent_destroy[[:space:]]*=[[:space:]]*true/\1# prevent_destroy stripped in temp copy for apply-mode mock tests/' "$f"
    rm -f "$f.bak"
  done
  if [ -n "$(efs_prevent_destroy_lines "$tmp")" ]; then
    red "FAIL apply suite: could not strip prevent_destroy in temp copy (suite could not run)"
    rm -rf "$tmp"; return 1
  fi
  rc=0
  tf_init "$tmp" tests/unit/apply || rc=1
  if [ "$rc" -eq 0 ]; then
    (cd "$tmp" && tf_test -test-directory=tests/unit/apply) || rc=$?
  fi
  rm -rf "$tmp"
  return "$rc"
}

overall=0
case "$SUITE" in
  static) suite_static || overall=1 ;;
  main)   suite_main   || overall=1 ;;
  apply)  suite_apply  || overall=1 ;;
  all)
    suite_static || overall=1
    echo "---- main suite (tests/unit) ----"
    suite_main   || overall=1
    echo "---- apply suite (tests/unit/apply, temp copy, prevent_destroy stripped) ----"
    suite_apply  || overall=1
    ;;
  *) red "unknown suite: $SUITE"; exit 2 ;;
esac

if [ "$overall" -eq 0 ]; then green "UNIT: ALL GREEN"; else red "UNIT: FAILURES (see above)"; fi
exit "$overall"
