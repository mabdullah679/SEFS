#!/usr/bin/env bash
# R3 wiring guard. fs_policy.tftest.hcl proves the policy DOCUMENT; this proves
# the module actually ATTACHES that document to this file system with the right
# ARNs. Not assertable in efs_mock.tftest.hcl: those values are unknown at plan
# and apply-mode runs can't tear down past prevent_destroy (TF 1.9.8).
# Exit 0 = pass, 1 = fail. Usage: check_policy_wiring.sh [module_dir]
set -euo pipefail

dir="${1:-$(cd "$(dirname "$0")/.." && pwd)}"

python3 - "$dir" <<'PY'
import re, sys, pathlib

d = pathlib.Path(sys.argv[1])
src = "\n".join(p.read_text() for p in sorted(d.glob("*.tf")))
src = re.sub(r"/\*.*?\*/", "", src, flags=re.S)
src = "\n".join(re.split(r"#|//", line, maxsplit=1)[0] for line in src.splitlines())

def block(text, start):
    i = text.index("{", start)
    depth = 0
    for j in range(i, len(text)):
        if text[j] == "{":
            depth += 1
        elif text[j] == "}":
            depth -= 1
            if depth == 0:
                return text[i + 1 : j]
    raise SystemExit("unbalanced braces")

def one(pattern, what):
    m = list(re.finditer(pattern, src))
    if len(m) != 1:
        print(f"FAIL: expected exactly 1 {what}, found {len(m)}")
        sys.exit(1)
    return block(src, m[0].start())

pol = one(r'resource\s+"aws_efs_file_system_policy"\s+"this"\s*{', "aws_efs_file_system_policy.this")
mod = one(r'module\s+"fs_policy"\s*{', 'module "fs_policy"')

need = [
    (pol, r"file_system_id\s*=\s*aws_efs_file_system\.this\.id\b", "policy attaches to aws_efs_file_system.this"),
    (pol, r"policy\s*=\s*module\.fs_policy\.json\b", "policy = module.fs_policy.json"),
    (mod, r'source\s*=\s*"\./policy"', 'fs_policy source = "./policy"'),
    (mod, r"file_system_arn\s*=\s*aws_efs_file_system\.this\.arn\b", "fs_policy.file_system_arn = this FS arn"),
    (mod, r"writer_access_point_arn\s*=\s*aws_efs_access_point\.writer\.arn\b", "fs_policy.writer_access_point_arn = writer AP arn"),
    (mod, r"reader_access_point_arn\s*=\s*aws_efs_access_point\.reader\.arn\b", "fs_policy.reader_access_point_arn = reader AP arn"),
    (mod, r"writer_role_arn\s*=\s*var\.writer_role_arn\b", "fs_policy.writer_role_arn = var.writer_role_arn"),
    (mod, r"reader_role_arn\s*=\s*var\.reader_role_arn\b", "fs_policy.reader_role_arn = var.reader_role_arn"),
]
fails = [w for b, p, w in need if not re.search(p, b)]
if re.search(r"bypass_policy_lockout_safety_check\s*=\s*true", pol):
    fails.append("bypass_policy_lockout_safety_check must not be true")
if fails:
    for f in fails:
        print("FAIL:", f)
    sys.exit(1)
print("PASS: FS policy document is wired to this FS, both APs and both roles (R3)")
PY
