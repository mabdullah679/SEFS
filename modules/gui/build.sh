#!/usr/bin/env bash
# Builds the map's static site into OUT_DIR, inside a pinned Node container (the host needs Docker,
# not Node). One source of truth: the Terraform apply calls this, and so does `make test-web`.
#
#   modules/gui/build.sh <web-dir> <out-dir> [node-image] [timeout-seconds]
#
# Deterministic (D27): `npm ci` installs exactly package-lock.json; three.js is copied from that
# install next to the page (no CDN). Output layout, referenced by index.html's import map:
#   index.html styles.css js/*.js vendor/three.module.min.js vendor/addons/renderers/CSS2DRenderer.js
set -euo pipefail
WEB_DIR="$(cd "${1:?web dir}" && pwd)"; OUT_DIR="${2:?out dir}"
NODE_IMAGE="${3:-node:22.12.0-alpine3.20}"; TIMEOUT="${4:-900}"
mkdir -p "$OUT_DIR"; OUT_DIR="$(cd "$OUT_DIR" && pwd)"
label="sefs-gui-build-$$"

# Watchdog: a stuck npm install must not hold the apply forever. Detached fds (see AGENTS.md §7).
( sleep "$TIMEOUT"; docker ps -q --filter "label=$label" | xargs -r docker kill ) >/dev/null 2>&1 </dev/null &
wpid=$!
# Run as the invoking user: on a Linux host (the GitHub runner) a root container leaves root-owned
# output that the caller cannot delete afterwards (CI apply failed on `rm -rf` 2026-10-28). Docker
# Desktop on macOS maps ownership anyway. HOME must be writable for npm's cache.
docker run --rm --label "$label" --user "$(id -u):$(id -g)" -e HOME=/tmp -e npm_config_cache=/tmp/npm \
  -v "$WEB_DIR:/src:ro" -v "$OUT_DIR:/dist" "$NODE_IMAGE" sh -ec '
  cp -R /src /tmp/work && cd /tmp/work
  npm ci --ignore-scripts --no-audit --no-fund >/dev/null
  npx tsc -p tsconfig.json --outDir /dist/js
  cp index.html styles.css /dist/
  mkdir -p /dist/vendor/addons/renderers
  cp node_modules/three/build/three.module.min.js /dist/vendor/
  cp node_modules/three/examples/jsm/renderers/CSS2DRenderer.js /dist/vendor/addons/renderers/
'
pkill -P "$wpid" 2>/dev/null || true; kill "$wpid" 2>/dev/null || true

for f in index.html styles.css js/main.js vendor/three.module.min.js vendor/addons/renderers/CSS2DRenderer.js; do
  [ -s "$OUT_DIR/$f" ] || { echo "build incomplete: $f missing" >&2; exit 1; }
done
echo "built $(find "$OUT_DIR" -type f | wc -l | tr -d ' ') files into $OUT_DIR"
