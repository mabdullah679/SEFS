#!/usr/bin/env bash
# Installs (or refreshes) the `sefs-bruno` AWS CLI profile. The profile holds NO
# credentials: only a credential_process that assumes the read-only role via the
# source profile you name. Idempotent (`aws configure set` rewrites the same keys).
#
#   bruno-profile.sh install <source-profile> <region> [name]
#   bruno-profile.sh remove  [name]
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cmd="${1:-}"; shift || true
case "$cmd" in
  install)
    SRC="${1:?source profile}"; REGION="${2:?region}"; NAME="${3:-sefs}"
    P="$NAME-bruno"
    aws configure set --profile "$P" credential_process "$HERE/bruno-creds.sh $SRC $NAME"
    aws configure set --profile "$P" region "$REGION"
    aws configure set --profile "$P" output json
    echo "profile '$P' -> assumes role $NAME-bruno-reader via profile '$SRC' (no stored credentials)"
    ;;
  remove)
    NAME="${1:-sefs}"; P="$NAME-bruno"
    for k in credential_process region output; do aws configure set --profile "$P" "$k" "" 2>/dev/null || true; done
    echo "profile '$P' keys cleared (an empty [profile $P] header may remain in ~/.aws/config)"
    ;;
  *) echo "usage: $0 install <source-profile> <region> [name] | remove [name]" >&2; exit 2 ;;
esac
