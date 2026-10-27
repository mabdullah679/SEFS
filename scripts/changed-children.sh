#!/usr/bin/env bash
# Maps the files changed in a git range to the child modules that must be re-applied.
#
#   changed-children.sh <base> <head>      e.g. changed-children.sh HEAD~1 HEAD
#
# Prints exactly one line:
#   full                 root wiring changed (or an unknown path): apply the whole mother
#   none                 nothing deployable changed (docs, tests, tooling): verify only
#   <child> [<child>…]   space-separated module names, in dependency order
#
# Rules (docs/COMPONENTS.md is the human version of this table):
#   modules/<x>/**            -> x   (modules/gui/web and modules/gui/api are part of gui: the apply rebuilds them)
#   apps/**                   -> images apps   (a new image tag flows into the task definitions)
#   main.tf variables.tf outputs.tf versions.tf *.tfvars  -> full
#   docs tests bruno scripts Makefile setup.sh README* PLAN* .github .gitignore secrets.manifest -> none
#   anything else             -> full  (fail safe: unknown means "redeploy everything")
set -euo pipefail
base="${1:?base ref}"; head="${2:?head ref}"
ORDER=(network security efs backup images apps observability access registry gui)

full=0; want=" "   # portable to bash 3.2 (macOS): no associative arrays
while IFS= read -r f; do
  [ -z "$f" ] && continue
  case "$f" in
    modules/*/*)
      m="${f#modules/}"; m="${m%%/*}"
      case " ${ORDER[*]} " in *" $m "*) want="$want$m " ;; *) full=1 ;; esac ;;
    apps/*)                      want="${want}images apps " ;;
    main.tf|variables.tf|outputs.tf|versions.tf|*.tfvars|*.tfvars.json) full=1 ;;
    docs/*|tests/*|bruno/*|scripts/*|.github/*|Makefile|setup.sh|README*|PLAN*|.gitignore|secrets.manifest|*.md|*.txt) ;;
    *) full=1 ;;
  esac
done < <(git diff --name-only "$base" "$head" --)

if [ "$full" = 1 ]; then echo full; exit 0; fi
out=()
for m in "${ORDER[@]}"; do case "$want" in *" $m "*) out+=("$m") ;; esac; done
[ "${#out[@]}" -gt 0 ] && echo "${out[*]}" || echo none
