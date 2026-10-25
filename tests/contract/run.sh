#!/usr/bin/env bash
# SEFS contract test: writer (1001:1000, rw) and reader (1002:1000, ro) share ONE
# named volume. Asserts the CONTRACTS.md section 3 log interface and the POSIX
# ownership/permission result. Exit 0 = every check passed; non-zero = at least one failed.
# Touches only sefs-contract* containers/volumes/images. Always runs `down -v`.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
cd "$HERE"

PROJECT=sefs-contract
VOLUME="${PROJECT}_shared"
WRITER_IMAGE=sefs-contract-writer:test
MIN_READS="${MIN_READS:-5}"
TIMEOUT_SECONDS="${TIMEOUT_SECONDS:-180}"

dc() { docker compose -p "$PROJECT" -f "$HERE/docker-compose.yml" "$@"; }
cleanup() { dc down -v --remove-orphans >/dev/null 2>&1 || true; }
trap cleanup EXIT

FAILS=0
pass() { printf 'PASS  %s\n' "$1"; }
fail() { printf 'FAIL  %s\n' "$1"; FAILS=$((FAILS + 1)); }
check() { # check "<description>" <command...>
  local desc="$1"; shift
  if "$@"; then pass "$desc"; else fail "$desc"; fi
}

WORK="$(mktemp -d "${TMPDIR:-/tmp}/sefs-contract.XXXXXX")"
trap 'cleanup; rm -rf "$WORK"' EXIT

echo "== clean start"
cleanup

echo "== build (linux/arm64)"
dc build --quiet || { echo "FAIL  image build"; exit 2; }

echo "== up"
dc up -d || { echo "FAIL  compose up"; dc logs --no-color; exit 2; }

echo "== waiting for >= ${MIN_READS} READ lines (timeout ${TIMEOUT_SECONDS}s)"
deadline=$(( $(date +%s) + TIMEOUT_SECONDS ))
while :; do
  n=$(dc logs --no-log-prefix --no-color reader 2>/dev/null | grep -c '^READ ' || true)
  [ "${n:-0}" -ge "$MIN_READS" ] && break
  if [ "$(date +%s)" -ge "$deadline" ]; then echo "timed out with ${n:-0} READ lines"; break; fi
  sleep 2
done

echo "== stop writer with SIGTERM, then reader"
dc stop -t 15 writer >/dev/null
WRITER_CID="$(dc ps -a -q writer)"
WRITER_EXIT="$(docker inspect -f '{{.State.ExitCode}}' "$WRITER_CID")"
dc stop -t 15 reader >/dev/null

dc logs --no-log-prefix --no-color writer >"$WORK/writer.log"
dc logs --no-log-prefix --no-color reader >"$WORK/reader.log"

# Inspect the volume read-only, as root, in a throwaway sefs- container.
docker run --rm --name sefs-contract-inspect --user 0:0 --entrypoint sh \
  -v "$VOLUME":/v:ro "$WRITER_IMAGE" -c '
    stat -c "DIR %u:%g %a" /v
    for f in /v/* /v/.[!.]*; do
      [ -e "$f" ] || continue
      printf "ENTRY %s %s %s\n" "$(stat -c "%u:%g %a" "$f")" "$(basename "$f")" "$(sha256sum "$f" | cut -d" " -f1)"
    done' >"$WORK/volume.txt"

echo "== logs (head)"
sed -n '1,3p' "$WORK/writer.log"; echo "..."
grep -E '^(READER_START|WRITE_PROBE|READ )' "$WORK/reader.log" | sed -n '1,4p'; echo "..."

# Derived sets: "<filename> <sha256>" per line.
sed -n 's/^WROTE \([^ ]*\) sha256=\([0-9a-f]\{64\}\)$/\1 \2/p' "$WORK/writer.log" | sort >"$WORK/wrote.txt"
sed -n 's/^READ \([^ ]*\) sha256=\([0-9a-f]\{64\}\)$/\1 \2/p' "$WORK/reader.log" | sort >"$WORK/read.txt"
awk '$1=="ENTRY" && $4 ~ /\.json$/ {print $4, $5}' "$WORK/volume.txt" | sort >"$WORK/onvolume.txt"

N_WROTE=$(wc -l <"$WORK/wrote.txt" | tr -d ' ')
N_READ=$(wc -l <"$WORK/read.txt" | tr -d ' ')
PROBE_LINES=$(grep -c '^WRITE_PROBE' "$WORK/reader.log" || true)

echo "== assertions (wrote=${N_WROTE} read=${N_READ})"
check "writer started as 1001:1000 on /mnt/shared" \
  grep -qx 'WRITER_START uid=1001 gid=1000 dir=/mnt/shared' "$WORK/writer.log"
check "reader started as 1002:1000 on /mnt/shared" \
  grep -qx 'READER_START uid=1002 gid=1000 dir=/mnt/shared' "$WORK/reader.log"
check "reader logged exactly one WRITE_PROBE line at INFO (got ${PROBE_LINES})" \
  test "$PROBE_LINES" -eq 1
check "reader logged WRITE_PROBE DENIED" \
  grep -Eq '^WRITE_PROBE DENIED [A-Za-z]+/[A-Za-z_]+$' "$WORK/reader.log"
check "reader never logged WRITE_PROBE ALLOWED" \
  sh -c "! grep -q '^WRITE_PROBE ALLOWED' '$WORK/reader.log'"
check "writer logged no WRITE_ERROR" \
  sh -c "! grep -q 'WRITE_ERROR' '$WORK/writer.log'"
check "writer wrote >= ${MIN_READS} files (got ${N_WROTE})" test "$N_WROTE" -ge "$MIN_READS"
check "reader read >= ${MIN_READS} files (got ${N_READ})" test "$N_READ" -ge "$MIN_READS"
check "every READ filename+sha256 matches a WROTE line" \
  sh -c "test -z \"\$(comm -23 '$WORK/read.txt' '$WORK/wrote.txt')\""
check "reader read each file at most once" \
  sh -c "test -z \"\$(cut -d' ' -f1 '$WORK/read.txt' | uniq -d)\""
check "files on volume == WROTE lines (name + sha256), no extra/partial .json" \
  cmp -s "$WORK/onvolume.txt" "$WORK/wrote.txt"
check "shared dir is 1001:1000 mode 775" grep -qx 'DIR 1001:1000 775' "$WORK/volume.txt"
check "every data file owned 1001:1000 mode 644 (group-readable)" \
  sh -c "test \"\$(awk '\$1==\"ENTRY\" && \$4 ~ /\\.json\$/' '$WORK/volume.txt' | wc -l)\" -ge 1 && \
         ! awk '\$1==\"ENTRY\" && \$4 ~ /\\.json\$/ && !(\$2==\"1001:1000\" && \$3==\"644\")' '$WORK/volume.txt' | grep -q ."
check "no temp files or probe file left on the volume" \
  sh -c "! grep -Eq '^ENTRY [^ ]+ [^ ]+ \\.' '$WORK/volume.txt'"
check "writer exited 0 on SIGTERM (got ${WRITER_EXIT})" test "$WRITER_EXIT" = "0"
check "writer logged a clean WRITER_STOP after SIGTERM" \
  grep -Eq '^WRITER_STOP signal=SIGTERM files=[0-9]+$' "$WORK/writer.log"

if [ "$FAILS" -ne 0 ]; then
  echo "== RESULT: FAIL (${FAILS} check(s) failed)"
  echo "-- volume listing"; cat "$WORK/volume.txt"
  echo "-- reader WRITE_PROBE lines"; grep '^WRITE_PROBE' "$WORK/reader.log" || true
  exit 1
fi
echo "== RESULT: PASS"
