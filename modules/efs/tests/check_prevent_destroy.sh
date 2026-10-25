#!/usr/bin/env bash
# R4 guard. `terraform test` cannot assert lifecycle meta-arguments, so this
# parses modules/efs/*.tf and requires that the aws_efs_file_system resource
# block contains `lifecycle { prevent_destroy = true }` (comments ignored).
# Exit 0 = present, 1 = missing/false. Usage: check_prevent_destroy.sh [module_dir]
set -euo pipefail

dir="${1:-$(cd "$(dirname "$0")/.." && pwd)}"

python3 - "$dir" <<'PY'
import re, sys, pathlib

d = pathlib.Path(sys.argv[1])
src = "\n".join(p.read_text() for p in sorted(d.glob("*.tf")))
# strip comments (#, //, /* */) so a commented-out guard does not count
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

fs = list(re.finditer(r'resource\s+"aws_efs_file_system"\s+"[^"]+"\s*{', src))
if len(fs) != 1:
    print(f"FAIL: expected exactly 1 aws_efs_file_system, found {len(fs)}")
    sys.exit(1)
body = block(src, fs[0].start())
lc = list(re.finditer(r"\blifecycle\s*{", body))
ok = any(re.search(r"\bprevent_destroy\s*=\s*true\b", block(body, m.start())) for m in lc)
if not ok:
    print("FAIL: aws_efs_file_system has no lifecycle { prevent_destroy = true } (R4)")
    sys.exit(1)
print("PASS: aws_efs_file_system has lifecycle { prevent_destroy = true } (R4)")
PY
