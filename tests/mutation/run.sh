#!/usr/bin/env bash
# Mutation harness: proves each unit test is a real guard, not a tautology.
#
#   tests/mutation/run.sh [TREE] [ID ...]
#
# For each table entry: rsync TREE to a fresh temp dir (the real tree is never
# touched), apply ONE exact-string mutation, run the named unit target, and
# require that target to go RED. Before any mutation, the UNMUTATED copy must
# be fully green and every named target must be seen PASSING there, otherwise
# a "killed" result would mean nothing.
#
# Verdicts:
#   KILLED    target went red ON AN ASSERTION (or a missing expected
#             validation failure) under the mutation (good)
#   SURVIVED  target stayed green: the guard is not real (bad)
#   ERROR     mutation could not be applied (original string not found / not
#             unique) or the target never reported: NOT a pass (bad)
# Exit 0 only if every selected mutation is KILLED.
#
# No AWS calls: same mock/blackhole setup as tests/unit/run.sh.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TREE="$(cd "${1:-$HERE/../..}" && pwd)"
shift || true
ONLY=()
[ "$#" -gt 0 ] && ONLY=("$@")
TF="${TF:-terraform}"
UNIT="tests/unit/run.sh"
BLACKHOLE="http://127.0.0.1:9"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/sefs-mutation.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

RED=$'\033[31m'; GRN=$'\033[32m'; YEL=$'\033[33m'; RST=$'\033[0m'

# ---------------------------------------------------------------------------
# Mutation table. Fields separated by " ::: ".
#   ID ::: R-ID ::: file (repo-relative) ::: op ::: original ::: mutated ::: target
# op:
#   sub      original must occur EXACTLY once; replaced by mutated
#   sub@N    replace the Nth occurrence (1-based) of a string that repeats
#   rmblock  delete the innermost { } block containing the line with `original`
#            (mutated is ignored, write -)
# "\n" in original/mutated means newline.
# target:
#   static                              tests/unit/run.sh static must FAIL
#   tests/unit/<f>.tftest.hcl::<run>    that run must report "fail"
#   tests/unit/apply/<f>.tftest.hcl::<run>  same, apply suite (temp copy, prevent_destroy stripped)
# Not in the table on purpose: root default backup_retention_days 35 -> 34.
# It IS rejected, but by the backup module's validation (an error), which m06
# already proves; the harness only counts assertion failures, so it is not a
# separate row. (Measured 2026-10-25: "Invalid value for variable".)
# Address/string assumptions are verified at run time: a string that is not
# found is an ERROR, never a silent skip.
# ---------------------------------------------------------------------------
read -r -d '' TABLE <<'EOF' || true
m01 ::: R12 ::: modules/efs/main.tf ::: sub ::: encrypted        = true ::: encrypted        = false ::: tests/unit/efs.tftest.hcl::r12_encrypted_generalpurpose_bursting
m02 ::: R12 ::: modules/efs/main.tf ::: sub ::: performance_mode = "generalPurpose" ::: performance_mode = "maxIO" ::: tests/unit/efs.tftest.hcl::r12_encrypted_generalpurpose_bursting
m03 ::: R12 ::: modules/efs/main.tf ::: sub ::: throughput_mode  = "bursting" ::: throughput_mode  = "elastic" ::: tests/unit/efs.tftest.hcl::r12_encrypted_generalpurpose_bursting
m04 ::: R15 ::: modules/efs/main.tf ::: sub ::: transition_to_ia = var.transition_to_ia ::: transition_to_ia = "AFTER_60_DAYS" ::: tests/unit/efs.tftest.hcl::r15_ia_after_30_days
m05 ::: R15 ::: variables.tf ::: sub ::: default     = "AFTER_30_DAYS" ::: default     = "AFTER_60_DAYS" ::: tests/unit/root.tftest.hcl::root_defaults_meet_contract
m06 ::: R14 ::: modules/backup/variables.tf ::: sub ::: condition     = var.retention_days >= 35 ::: condition     = var.retention_days >= 30 ::: tests/unit/backup.tftest.hcl::r14_rejects_34_day_retention
m08 ::: R14 ::: modules/backup/main.tf ::: sub ::: resources    = var.resource_arns ::: resources    = [] ::: tests/unit/backup.tftest.hcl::r14_backup_35_days_selects_efs
m09 ::: R9 ::: modules/security/main.tf ::: sub ::: referenced_security_group_id = aws_security_group.apps.id ::: cidr_ipv4                    = "10.0.0.0/8" ::: tests/unit/security.tftest.hcl::r09_sg_efs_only_2049_from_sg_apps
m10 ::: R9 ::: modules/security/main.tf ::: sub ::: description = "SEFS EFS mount targets. Ingress 2049 from sg-apps only." ::: description = "SEFS EFS mount targets. Ingress 2049 from sg-apps only."\n  ingress {\n    from_port   = 2049\n    to_port     = 2049\n    protocol    = "tcp"\n    cidr_blocks = ["10.0.0.0/8"]\n  } ::: tests/unit/security.tftest.hcl::r09_sg_efs_only_2049_from_sg_apps
m11 ::: R3 ::: modules/apps/main.tf ::: sub ::: readOnly      = true ::: readOnly      = false ::: tests/unit/apps.tftest.hcl::r03_reader_ro_config
m12 ::: R3 ::: modules/apps/main.tf ::: sub ::: Action    = ["elasticfilesystem:ClientMount"] ::: Action    = ["elasticfilesystem:ClientMount", "elasticfilesystem:ClientWrite"] ::: tests/unit/apps.tftest.hcl::r03_reader_ro_config
m13 ::: R3 ::: modules/efs/policy/main.tf ::: sub ::: actions   = ["elasticfilesystem:ClientMount"] ::: actions   = ["elasticfilesystem:ClientMount", "elasticfilesystem:ClientWrite"] ::: tests/unit/efs_policy.tftest.hcl::r03_fs_policy_reader_mount_only
m14 ::: R3 ::: modules/efs/policy/main.tf ::: rmblock ::: sid       = "DenyReaderWriteAndRoot" ::: - ::: tests/unit/efs_policy.tftest.hcl::r03_fs_policy_reader_explicit_deny
m15 ::: R3 ::: modules/apps/main.tf ::: sub@2 ::: transit_encryption = "ENABLED" ::: transit_encryption = "DISABLED" ::: tests/unit/apps.tftest.hcl::r03_reader_ro_config
m16 ::: R3 ::: modules/apps/main.tf ::: sub@2 ::: iam             = "ENABLED" ::: iam             = "DISABLED" ::: tests/unit/apps.tftest.hcl::r03_reader_ro_config
m17 ::: R3 ::: modules/efs/policy/main.tf ::: rmblock ::: sid       = "DenyInsecureTransport" ::: - ::: tests/unit/efs_policy.tftest.hcl::fs_policy_no_anonymous_no_root_no_plaintext
m18 ::: R2 ::: modules/apps/main.tf ::: sub ::: readOnly      = false ::: readOnly      = true ::: tests/unit/apps.tftest.hcl::r02_writer_rw_config
m19 ::: R4 ::: modules/efs/main.tf ::: sub ::: prevent_destroy = true ::: prevent_destroy = false ::: static
m20 ::: R4 ::: modules/efs/main.tf ::: rmblock ::: prevent_destroy = true ::: - ::: static
m21 ::: R5 ::: modules/network/variables.tf ::: sub ::: condition     = var.az_count >= 2 ::: condition     = var.az_count >= 1 ::: tests/unit/network.tftest.hcl::r05_rejects_single_az
m22 ::: R6 ::: modules/apps/main.tf ::: sub@2 ::: assign_public_ip = false ::: assign_public_ip = true ::: tests/unit/apps.tftest.hcl::r06_services_private_no_public_ip
m23 ::: R6 ::: modules/network/main.tf ::: sub@2 ::: map_public_ip_on_launch = false ::: map_public_ip_on_launch = true ::: tests/unit/network.tftest.hcl::r06_private_subnets_no_public_ip
m24 ::: R7 ::: modules/efs/main.tf ::: sub ::: security_groups = [var.efs_security_group_id] ::: security_groups = [] ::: tests/unit/efs.tftest.hcl::r07_mount_target_per_private_az
m25 ::: R8 ::: modules/apps/main.tf ::: sub@1 ::: security_groups  = [var.apps_security_group_id] ::: security_groups  = [] ::: tests/unit/apps.tftest.hcl::r08_both_services_use_sg_apps
m26 ::: R10 ::: modules/efs/main.tf ::: sub ::: uid = var.reader_uid ::: uid = var.writer_uid ::: tests/unit/efs.tftest.hcl::r10_access_points_posix_and_same_root
m27 ::: R13 ::: modules/efs/main.tf ::: sub ::: kms_key_id = var.kms_key_arn ::: kms_key_id = null ::: tests/unit/apply/efs_wiring.tftest.hcl::r13_cmk_passed_through
m28 ::: R3 ::: modules/efs/main.tf ::: sub ::: policy         = module.fs_policy.json ::: policy         = jsonencode({ Version = "2012-10-17", Statement = [] }) ::: tests/unit/apply/efs_wiring.tftest.hcl::r03_fs_policy_attached_to_shared_fs
m29 ::: CTR ::: modules/efs/main.tf ::: sub ::: status = "DISABLED" ::: status = "ENABLED" ::: tests/unit/efs.tftest.hcl::efs_automatic_backups_disabled
EOF

# Apply one mutation in place to $1 (a temp copy). Prints nothing on success.
mutate() {
  local copy="$1" file="$2" op="$3" orig="$4" mut="$5"
  python3 - "$copy/$file" "$op" "$orig" "$mut" <<'PY'
import sys
path, op, orig, mut = sys.argv[1:5]
orig = orig.replace("\\n", "\n"); mut = mut.replace("\\n", "\n")
try:
    src = open(path).read()
except FileNotFoundError:
    sys.exit(f"file not found: {path}")
n = src.count(orig)
if op == "sub":
    if n != 1:
        sys.exit(f"expected exactly 1 occurrence, found {n}: {orig!r}")
    src = src.replace(orig, mut, 1)
elif op.startswith("sub@"):
    k = int(op[4:])
    if n < k:
        sys.exit(f"wanted occurrence {k}, found {n}: {orig!r}")
    idx = -1
    for _ in range(k):
        idx = src.index(orig, idx + 1)
    src = src[:idx] + mut + src[idx + len(orig):]
elif op == "rmblock":
    if n != 1:
        sys.exit(f"rmblock anchor must occur exactly once, found {n}: {orig!r}")
    a = src.index(orig)
    # walk back to the "{" that opens the innermost enclosing block
    depth, i = 0, a
    while i > 0:
        i -= 1
        c = src[i]
        if c == "}": depth += 1
        elif c == "{":
            if depth == 0: break
            depth -= 1
    else:
        sys.exit("no enclosing block")
    start = src.rfind("\n", 0, i) + 1          # start of the block's header line
    depth, j = 0, i
    while j < len(src):
        if src[j] == "{": depth += 1
        elif src[j] == "}":
            depth -= 1
            if depth == 0: break
        j += 1
    end = src.find("\n", j)
    end = len(src) if end == -1 else end + 1
    src = src[:start] + src[end:]
else:
    sys.exit(f"unknown op {op}")
open(path, "w").write(src)
PY
}

strip_prevent_destroy() {
  local f
  for f in "$1"/modules/efs/*.tf; do
    [ -e "$f" ] || continue
    sed -i.bak -E 's/^([[:space:]]*)prevent_destroy[[:space:]]*=[[:space:]]*true/\1# prevent_destroy stripped (apply-suite temp copy)/' "$f"
    rm -f "$f.bak"
  done
}

# Run the unit file for TARGET inside COPY; print the run's status word
# (pass|fail|skip|missing|initerror) on stdout, full log to $3.
run_target() {
  local copy="$1" target="$2" log="$3"
  local file="${target%%::*}" run="${target##*::}" dir
  dir="$(dirname "$file")"
  if [ "$dir" = "tests/unit/apply" ]; then strip_prevent_destroy "$copy"; fi
  if ! (cd "$copy" && "$TF" init -backend=false -input=false -no-color -test-directory="$dir" >"$log" 2>&1); then
    echo initerror; return 0
  fi
  (cd "$copy" && HTTPS_PROXY="$BLACKHOLE" HTTP_PROXY="$BLACKHOLE" https_proxy="$BLACKHOLE" http_proxy="$BLACKHOLE" \
     NO_PROXY="" no_proxy="" AWS_EC2_METADATA_DISABLED=true \
     "$TF" test -no-color -test-directory="$dir" -filter="$file" >>"$log" 2>&1) || true
  local st
  st="$(grep -E "^[[:space:]]*run \"${run}\"\.\.\. (pass|fail|skip)" "$log" | tail -1 | sed -E 's/.*\.\.\. //')"
  echo "${st:-missing}"
}

selected() {
  [ "${#ONLY[@]}" -eq 0 ] && return 0
  local x; for x in ${ONLY[@]+"${ONLY[@]}"}; do [ "$x" = "$1" ] && return 0; done
  return 1
}

# ---------------------------------------------------------------- baseline
echo "== baseline: unmutated copy must be all green =="
BASE="$WORK/base"
rsync -a --exclude .git "$TREE"/ "$BASE"/
if ! bash "$BASE/$UNIT" "$BASE" all >"$WORK/baseline.log" 2>&1; then
  echo "${RED}BASELINE NOT GREEN${RST}: mutation results would be meaningless. Log tail:"
  tail -40 "$WORK/baseline.log"
  exit 1
fi
echo "${GRN}baseline green${RST}"

declare -a ROWS=()
fails=0
while IFS= read -r line; do
  [ -z "$line" ] && continue
  # split on " ::: "
  rest="$line"
  f=()
  while [[ "$rest" == *" ::: "* ]]; do f+=("${rest%% ::: *}"); rest="${rest#* ::: }"; done
  f+=("$rest")
  if [ "${#f[@]}" -ne 7 ]; then echo "${RED}bad table row:${RST} $line"; exit 2; fi
  id="${f[0]}" rid="${f[1]}" file="${f[2]}" op="${f[3]}" orig="${f[4]}" mut="${f[5]}" target="${f[6]}"
  selected "$id" || continue

  verdict="" detail=""
  # 1) target must have PASSED in the unmutated baseline (static: covered by green baseline)
  if [ "$target" != "static" ]; then
    bst="$(grep -E "^[[:space:]]*run \"${target##*::}\"\.\.\. (pass|fail|skip)" "$WORK/baseline.log" | tail -1 | sed -E 's/.*\.\.\. //')"
    if [ "$bst" != "pass" ]; then
      verdict="ERROR"; detail="target '${target##*::}' is '${bst:-missing}' in the UNMUTATED baseline"
    fi
  fi
  # 2) mutate a fresh copy and require the target to go red
  if [ -z "$verdict" ]; then
    mcopy="$WORK/m-$id"; rsync -a "$BASE"/ "$mcopy"/   # BASE = clean copy, already init'ed
    if ! err="$(mutate "$mcopy" "$file" "$op" "$orig" "$mut" 2>&1)"; then
      verdict="ERROR"; detail="mutation not applied: $err"
    elif [ "$target" = "static" ]; then
      if bash "$mcopy/$UNIT" "$mcopy" static >"$WORK/m-$id.log" 2>&1; then
        verdict="SURVIVED"; detail="static R4 check still passed"
      else
        verdict="KILLED"; detail="static check failed as required"
      fi
    else
      mst="$(run_target "$mcopy" "$target" "$WORK/m-$id.log")"
      case "$mst" in
        fail)
          # Only a failed ASSERTION / a missing expected validation failure
          # counts. A run that fails because the mutation broke the config
          # (syntax, type error) proves nothing about the guard.
          if grep -qE 'Test assertion failed|Missing expected failure' "$WORK/m-$id.log"; then
            verdict="KILLED"; detail="${target##*::} -> fail ($(grep -oE 'Test assertion failed|Missing expected failure' "$WORK/m-$id.log" | head -1))"
          else
            verdict="ERROR"; detail="${target##*::} failed but not on an assertion: $(grep -m1 -E '^Error:' "$WORK/m-$id.log" || echo '?')"
          fi ;;
        pass) verdict="SURVIVED"; detail="${target##*::} still passes" ;;
        *)    verdict="ERROR";    detail="${target##*::} -> $mst (did not report a verdict)" ;;
      esac
    fi
    rm -rf "$mcopy"
  fi
  [ "$verdict" = "KILLED" ] || fails=$((fails + 1))
  ROWS+=("$id|$rid|$file|$verdict|$detail")
  case "$verdict" in
    KILLED) c="$GRN" ;; SURVIVED) c="$RED" ;; *) c="$YEL" ;;
  esac
  printf '%s %-4s %-28s %s%-8s%s %s\n' "$id" "$rid" "$file" "$c" "$verdict" "$RST" "$detail"
done <<<"$TABLE"

# ---------------------------------------------------------------- control
# A semantically empty mutation (comment text only) MUST survive. If the
# harness reported it KILLED, every KILLED above would be suspect.
echo
echo "== control: a no-op mutation must SURVIVE =="
ccopy="$WORK/control"; rsync -a "$BASE"/ "$ccopy"/
control_ok=0
if mutate "$ccopy" modules/efs/main.tf sub "  # R15" "  # R15 (mutation-harness control: comment only)" "-" 2>"$WORK/control.err"; then
  cst="$(run_target "$ccopy" "tests/unit/efs.tftest.hcl::r15_ia_after_30_days" "$WORK/control.log")"
  if [ "$cst" = "pass" ]; then echo "${GRN}control survived as required${RST}"; control_ok=1
  else echo "${RED}control did NOT survive (status '$cst'): harness is unreliable${RST}"; fi
else
  echo "${RED}control mutation could not be applied: $(cat "$WORK/control.err")${RST}"
fi
rm -rf "$ccopy"

echo
echo "== mutation summary =="
printf '%-4s %-4s %-30s %-8s\n' ID R-ID FILE VERDICT
for r in ${ROWS[@]+"${ROWS[@]}"}; do
  IFS='|' read -r id rid file verdict _ <<<"$r"
  case "$verdict" in KILLED) c="$GRN" ;; SURVIVED) c="$RED" ;; *) c="$YEL" ;; esac
  printf '%-4s %-4s %-30s %s%-8s%s\n' "$id" "$rid" "$file" "$c" "$verdict" "$RST"
done
total="${#ROWS[@]}"  # bash 3.2-safe: ROWS declared
if [ "$total" -eq 0 ]; then echo "${RED}no mutations selected${RST}"; exit 1; fi
if [ "$fails" -eq 0 ]; then
  echo "${GRN}ALL $total MUTATIONS KILLED${RST}"
else
  echo "${RED}$fails of $total mutations NOT killed (SURVIVED or ERROR)${RST}"
fi
[ "$control_ok" -eq 1 ] || { echo "${RED}control failed: results not trustworthy${RST}"; exit 1; }
[ "$fails" -eq 0 ]
