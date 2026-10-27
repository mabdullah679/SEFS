#!/usr/bin/env bash
# Proves scripts/changed-children.sh maps paths correctly, on a throwaway git repo.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; SCRIPT="$HERE/../../scripts/changed-children.sh"
W="$(mktemp -d "${TMPDIR:-/tmp}/sefs-ci.XXXXXX")"; trap 'rm -rf "$W"' EXIT
cd "$W" && git init -q && git -c user.email=t@t -c user.name=t commit -q --allow-empty -m base
fail=0
case_() { # name, expected, files...
  local name="$1" expect="$2"; shift 2
  git checkout -q -B case
  for f in "$@"; do mkdir -p "$(dirname "$f")"; echo "$RANDOM" > "$f"; git add "$f"; done
  git -c user.email=t@t -c user.name=t commit -q -m "$name"
  local got; got="$(bash "$SCRIPT" HEAD~1 HEAD)"
  if [ "$got" = "$expect" ]; then echo "PASS $name -> '$got'"; else echo "FAIL $name -> '$got' (expected '$expect')"; fail=1; fi
  git checkout -q master 2>/dev/null || git checkout -q main
}
case_ "efs module only"              "efs"                 modules/efs/main.tf
case_ "two modules, dependency order" "network apps"       modules/apps/main.tf modules/network/main.tf
case_ "app code -> images + apps"    "images apps"         apps/writer-python/writer.py
case_ "root wiring -> full"          "full"                main.tf
case_ "tfvars -> full"               "full"                prod.auto.tfvars
case_ "docs/tests/bruno -> none"     "none"                docs/X.md tests/unit/x.tftest.hcl bruno/sefs/a.bru README.md
case_ "unknown path -> full"         "full"                mystery/thing.yaml
case_ "unknown module dir -> full"   "full"                modules/newthing/main.tf
case_ "module + docs -> module only" "security"            modules/security/main.tf docs/Y.md
case_ "map page or API -> gui"       "gui"                 modules/gui/web/src/main.ts modules/gui/api/app.py
case_ "gui after registry"           "registry gui"        modules/gui/main.tf modules/registry/main.tf
[ $fail = 0 ] && echo "ci selftest: ALL PASS" || { echo "ci selftest: FAIL"; exit 1; }
