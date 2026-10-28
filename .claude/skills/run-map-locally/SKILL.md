---
name: run-map-locally
description: Use when asked to run, open, demo or screenshot the SEFS 2.5D map (modules/gui) on localhost without deploying or touching AWS — the page is served from a local Python server and the read-only API is answered by the test suite's fake AWS.
---

# Run the map on localhost (no AWS)

```bash
make map-local                 # builds the page in Docker (pinned Node), then serves http://localhost:8080/
SCENARIO=sg-open make map-local   # or reader-down | empty: the fake AWS answers change, the map colours follow
```

What it is: `modules/gui/dev/local.py`, Python 3.12 stdlib. It serves the real build output, answers
`/config.json` with `local: true` (the page then skips the Cognito login) and routes `/api/*` through the
real `Router` in `modules/gui/api/app.py` fed by `FakeBoto3` + `canned()` from
`modules/gui/api/tests/test_app.py`. Nothing calls AWS. Ctrl-C stops it; the build lands in a temp dir.

Needs: Docker running (for the page build; `node:22.12.0-alpine3.20` is pulled once, ~50 MB), Python 3.
Already-built page: `python3 modules/gui/dev/local.py --dist <dir> --port 8080`.

Smoke without a browser:
```bash
curl -s localhost:8080/api/overview | python3 -c "import sys,json; j=json.load(sys.stdin); print(j['overall'], len(j['nodes']))"
curl -s localhost:8080/api/cost | python3 -c "import sys,json; print(json.load(sys.stdin)['rates']['perHour'])"
```

Screenshot it (headless Chrome over CDP, no npm deps): a `localshot.mjs` lives in the session scratchpad
pattern; the gist is `Google Chrome --headless=new --remote-debugging-port=9334`, `Page.navigate`, wait until
`#overall` is not `…`, `Page.captureScreenshot`; click the canvas centre (the EFS slab) to open a room.

Gotchas: port 8080 busy → `--port 8081`; the server prints one line per request to stderr; the fake AWS
has two NATs, two tasks, ten alarms, a 35-day backup plan, so the cost line reads ≈ US$0.17/h.
