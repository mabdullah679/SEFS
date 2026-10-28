---
name: run-local-stack
description: Use when asked to run, demo, test or screenshot the whole SEFS stack locally with no AWS (writer + reader containers on a shared volume plus the 2.5D map reading them), or to set that up on a fresh machine. Not for the cloud deploy (that is ./sefs setup / CI).
---

# Run the whole stack locally (no AWS)

Full write-up: `docs/LOCAL.md`. The short recipe:

```bash
./sefs local           # the one command: local-up then map-local (Ctrl-C stops the map); ./sefs local down cleans up
# or step by step:
make local-up          # writer + reader containers on volume sefs-local_shared (first run: 3-5 min Java build)
make local-logs        # WROTE / READ / WRITE_PROBE DENIED lines; Ctrl-C keeps them running
make map-local         # the map at http://localhost:8080 reading those containers (auto-detects them)
make local-down        # stop + delete the volume
```

Needs Docker running, Python 3, make. No AWS login, no Node, no Java on the host.

## Prove it is the real stack, not stand-ins

```bash
docker compose ps                                                  # writer, reader: running
curl -s localhost:8080/config.json | grep -o '"region": "local"'   # the map chose the Docker source
curl -s localhost:8080/api/overview | python3 -c "import sys,json; j=json.load(sys.stdin); print(j['overall'], sorted(n['id'] for n in j['nodes'] if n['kind']=='task'))"
# -> ok ['sefs-local-reader-1', 'sefs-local-writer-1']
curl -s localhost:8080/api/room/efs | python3 -c "import sys,json; r=json.load(sys.stdin); print(r['readerWriteDenied'], r['localControl'][:40])"
# -> True reader mounts the volume read-only ...
docker stop sefs-local-reader-1 && sleep 12 && curl -s localhost:8080/api/overview | python3 -c "import sys,json; print(json.load(sys.stdin)['overall'])"   # -> down
docker start sefs-local-reader-1
```

Screenshot: headless Chrome over CDP with no deps works (`"/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" --headless=new --remote-debugging-port=9334`, navigate, wait until `#overall` is not `…`, `Page.captureScreenshot`); on Linux use `google-chrome` or `chromium`.

## Tests that need neither Docker nor AWS

```bash
python3 -m unittest discover -s modules/gui/dev/tests   # the Docker adapter on a fake docker CLI
python3 -m unittest discover -s modules/gui/api/tests   # the map's API on a fake AWS
```

## Gotchas

- `make map-local` with the pair stopped falls back to canned data and says so on its first line; pass
  `--source docker` to refuse instead.
- `WRITE_PROBE ALLOWED` in the reader log means the `read_only: true` mount flag is gone from docker-compose.yml.
- The map refreshes every 10 s locally; a container you stop shows as down on the next refresh.
- Only the `sefs-local` compose project is read; `tests/contract` uses a different project name and never collides.
