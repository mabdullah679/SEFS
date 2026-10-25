#!/usr/bin/env bash
# Runs every proof for modules/security. Offline: HTTP(S)_PROXY points at a closed
# local port, so any AWS API call would fail the run rather than reach AWS.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
mod="$(cd "$here/.." && pwd)"
cd "$mod"
terraform init -backend=false -input=false >/dev/null
HTTPS_PROXY=http://127.0.0.1:9 HTTP_PROXY=http://127.0.0.1:9 NO_PROXY= AWS_EC2_METADATA_DISABLED=true \
  terraform test -no-color
"$here/check_sg_rules.sh" "$mod"
