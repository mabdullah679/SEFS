# tests/contract — local writer/reader POSIX contract test

Runs the real writer and reader images (linux/arm64) against ONE shared Docker named
volume and checks the log interface in [docs/CONTRACTS.md](../../docs/CONTRACTS.md) §3
"apps (application code)" plus the POSIX result on disk. Covers R2/R3/R10 *behavior*
locally; it is not proof of the AWS controls.

```
init (root, once) --chown 1001:1000, chmod 0775--> volume sefs-contract_shared
writer 1001:1000  --rw-->  /mnt/shared  <--:ro (nocopy)--  reader 1002:1000
```

## Important: `:ro` here only stands in for the real control

Locally the reader is read-only because of the Docker `read_only: true` mount flag. On
real EFS a mount flag is **not** the control (the container could ask for rw): read-only
is enforced by IAM — the reader task role has `ClientMount` only and the file-system
policy explicitly denies it `ClientWrite`. This test cannot exercise IAM. The mutation
below shows why that matters: with the flag removed, the reader **can** write, because
the shared dir is group-writable (0775, GID 1000) by design.

## Run it

Needs Docker with buildx/compose v2 only (no Java, Maven or Python on the host).

```
tests/contract/run.sh          # exit 0 = PASS, 1 = an assertion failed, 2 = build/up failed
```

Knobs: `MIN_READS` (default 5), `TIMEOUT_SECONDS` (default 180). Always ends with
`docker compose -p sefs-contract down -v`; touches only `sefs-contract*` resources.

## What it asserts

| Check | Source |
|---|---|
| `WRITER_START uid=1001 gid=1000 dir=/mnt/shared`, `READER_START uid=1002 gid=1000 dir=/mnt/shared` | logs |
| exactly one INFO `WRITE_PROBE` line, and it is `WRITE_PROBE DENIED <Class>/<errno>` | reader log |
| no `WRITE_ERROR` | writer log |
| >= `MIN_READS` WROTE and READ lines; every READ name+sha256 equals a WROTE line; no file read twice | logs |
| files on the volume == WROTE set (name + sha256 recomputed on disk) | volume |
| dir 1001:1000 775, every `*.json` 1001:1000 644, no temp/probe file left | volume |
| writer exits 0 on SIGTERM and logs `WRITER_STOP signal=SIGTERM` | docker inspect, log |

## Mutation proof (assertions are real)

Edit `docker-compose.yml`, reader volume `read_only: true` -> `read_only: false`, run
`run.sh`: it must FAIL on the probe checks (reader logs `WRITE_PROBE ALLOWED`). Reverse
that exact edit, run again: PASS.
