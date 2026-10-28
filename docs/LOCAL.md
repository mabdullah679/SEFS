# Local-only deployment (no AWS)

Everything the stack does, on one machine: the real writer and reader as containers on a shared
Docker volume, and the 2.5D map reading those containers. Nothing is simulated except what Docker
cannot provide (listed below). Written for a person or agent setting this up on a fresh machine.

```
 make local-up ──► docker compose: init (chown 1001:1000, 0775) → writer (UID 1001, rw) → reader (UID 1002, ro)
                                   volume sefs-local_shared = the file system, network sefs-local_default = the VPC
 make map-local ──► python3 modules/gui/dev/local.py: serves the built page on http://localhost:8080
                    /api/* = the real Router (modules/gui/api/app.py) fed by local_docker.py, which reads
                    `docker compose ps`, `docker inspect`, `docker volume`, `docker network`, `docker logs`
```

## Prerequisites

- Docker Desktop or Engine with Compose v2 and `buildx`, running. Python 3.10+, `make`, `bash`.
- Nothing else: Java, Maven, Node and Python packages all live inside containers. No AWS account, no
  credentials, no network calls after the images are built (first build pulls `python:3.12.8-slim-bookworm`,
  `maven:3.9.9`, `eclipse-temurin:21` and `node:22.12.0-alpine3.20`, about 1.2 GB on a fresh machine).
- Ports: 8080 for the map (`--port` changes it). Nothing else listens.

## Run it (identical on macOS, Linux, WSL2)

The single command, after cloning: **`./sefs local`**. It runs steps 2 and 4 below and prints the address; `./sefs local down` is step 5. The steps, spelled out:

1. `git clone … sefs && cd sefs`
2. `make local-up` — builds both app images (the Java build inside Docker takes 3 to 5 minutes the first
   time) and starts the pair. `docker compose ps` shows `writer` and `reader` running.
3. `make local-logs` — `WROTE <file> sha256=…` every 5 s from the writer, the same file and hash as `READ …`
   from the reader, and one `WRITE_PROBE DENIED … EROFS` from the reader at start. Ctrl-C leaves them running.
4. `make map-local` — builds the page (Node in Docker, ~1 minute) and serves http://localhost:8080. The
   server prints which source it chose; with the pair running it is the Docker stack. Open the page: no
   login in local mode. Hover a box for facts, click the volume, a task or the network for its room.
5. `make local-down` — stops both containers and deletes the volume and its files. Ctrl-C stops the map.

### If something refuses to run

- `the local stack is not running` from `make map-local`: run `make local-up` first, or
  `python3 modules/gui/dev/local.py --source canned` for the page with made-up data.
- `port 8080` busy: `python3 modules/gui/dev/local.py --port 8081`.
- Reader shows `WRITE_PROBE ALLOWED`: the volume is mounted read-write for the reader; check the `read_only: true`
  line under `reader` in [../docker-compose.yml](../docker-compose.yml).
- Build fails pulling images: a slow link is the usual cause; `docker pull` each base image by hand, then retry.
- Apple Silicon vs x86: no `platform:` is pinned; each machine builds native images.

## What the map shows locally, and what it does not

| On the map | Comes from | Note |
|---|---|---|
| VPC plate, one private subnet, AZ `local` | `docker network inspect sefs-local_default` | real CIDR and gateway |
| writer task, reader task, their services, the cluster | `docker compose ps` + `docker inspect` | state, image, user, IP, start time |
| file system `sefs-local_shared`, size in bytes, file count | `docker volume inspect` + `du` inside the writer | real bytes on disk |
| one mount target per container | each container's mount of `/mnt/shared` | IP = container IP; rw / ro = Docker's flag |
| writer / reader access points | each container's user (1001:1000 / 1002:1000) | |
| log tail | `docker logs --timestamps` | the same `WROTE` / `READ` / `WRITE_PROBE` lines |
| EFS room "write control (local)" | the reader's latest `WRITE_PROBE` line | there is no file-system policy locally: the kernel refuses the ro mount |
| **not shown**: NAT gateways, security groups, alarms, backups, a file-system policy, prices and spend | Docker has none | backup reads `unknown: no backup locally`; cost reads "not metered: this is your machine" |

## Tests

```bash
make test-contract                                   # the one-shot proof: writer + reader on a volume, 16 checks, tears itself down
python3 -m unittest discover -s modules/gui/dev/tests   # the Docker adapter against a fake docker CLI (6 tests, no Docker needed)
python3 -m unittest discover -s modules/gui/api/tests   # the map's API against a fake AWS (20 tests)
```

Live smoke with the pair up and the map running:

```bash
curl -s localhost:8080/api/overview | python3 -c "import sys,json; j=json.load(sys.stdin); print(j['overall'], [n['id'] for n in j['nodes'] if n['kind']=='task'])"
curl -s "localhost:8080/api/logs?app=reader&limit=3"
curl -s localhost:8080/api/room/efs | python3 -c "import sys,json; print(json.load(sys.stdin)['readerWriteDenied'])"   # True
```

## Layout

| Path | Role |
|---|---|
| [../docker-compose.yml](../docker-compose.yml) | the pair, kept running; `make local-up/logs/down` |
| [../modules/gui/dev/local.py](../modules/gui/dev/local.py) | the map server; `--source docker\|canned\|auto`, `--port`, `--dist` |
| [../modules/gui/dev/local_docker.py](../modules/gui/dev/local_docker.py) | Docker → boto3-shaped answers for the Router |
| [../modules/gui/dev/tests/test_local_docker.py](../modules/gui/dev/tests/test_local_docker.py) | the adapter's tests |
| [../tests/contract](../tests/contract) | the one-shot POSIX contract proof (its own compose file) |
| [../.claude/skills/run-local-stack/SKILL.md](../.claude/skills/run-local-stack/SKILL.md) | the agent recipe for all of the above |

## Design notes

**Docker facts, AWS shapes.** The Router was not forked: `local_docker.py` answers the same boto3 method
names the Router already calls, so health rules, rooms and the log filter are identical to the cloud. The
alternative, a second local-only API, would drift from the real one.

**Absent means absent.** Docker has no NAT, security groups, alarms, backups or prices; the adapter returns
empty lists or raises, and the map shows nothing or `unknown` with the reason. Faking an alarm or a policy
would make the local run prove something the cloud run has to prove for real.

**The read-only proof is the reader's own log line.** Locally the write refusal comes from the kernel (ro
mount), not from an EFS policy; the EFS room says so and uses the reader's `WRITE_PROBE DENIED` line as the
evidence, the same line the cloud e2e step E2 checks.
