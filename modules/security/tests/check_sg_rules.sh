#!/usr/bin/env bash
# R9 structural guard that terraform test cannot express: across modules/security
#   - exactly 1 aws_vpc_security_group_ingress_rule, and it targets sg-efs;
#   - zero ingress rules target sg-apps;
#   - no inline ingress/egress blocks and no legacy aws_security_group_rule;
#   - no cidr_ipv4/cidr_ipv6/prefix_list_id inside any ingress rule.
# Exit 0 = pass, 1 = fail. Usage: check_sg_rules.sh [module_dir]
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

fails = []
ing = list(re.finditer(r'resource\s+"aws_vpc_security_group_ingress_rule"\s+"[^"]+"\s*{', src))
if len(ing) != 1:
    fails.append(f"expected exactly 1 aws_vpc_security_group_ingress_rule, found {len(ing)}")
for m in ing:
    b = block(src, m.start())
    if not re.search(r"security_group_id\s*=\s*aws_security_group\.efs\.id", b):
        fails.append("ingress rule does not target aws_security_group.efs")
    if not re.search(r"referenced_security_group_id\s*=\s*aws_security_group\.apps\.id", b):
        fails.append("ingress rule source is not aws_security_group.apps")
    if re.search(r"\b(cidr_ipv4|cidr_ipv6|prefix_list_id)\s*=", b):
        fails.append("ingress rule has a CIDR/prefix-list source")
if re.search(r'resource\s+"aws_security_group_rule"', src):
    fails.append("legacy aws_security_group_rule present")
for m in re.finditer(r'resource\s+"aws_security_group"\s+"[^"]+"\s*{', src):
    if re.search(r"\b(ingress|egress)\s*{", block(src, m.start())):
        fails.append("inline ingress/egress block in aws_security_group")

if fails:
    for f in fails:
        print("FAIL:", f)
    sys.exit(1)
print("PASS: sg-efs has exactly one ingress rule (TCP 2049 from sg-apps), no CIDR, no inline rules (R9)")
PY
