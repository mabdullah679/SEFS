tests/contract - local writer/reader test

What it is
A local Docker test. It runs the real writer image (user 1001, group 1000) and the real
reader image (user 1002, group 1000) against one shared Docker volume. The writer can
write; the reader is mounted read-only. It then checks the log lines the contract
(docs/CONTRACTS.md section 3) promises, and checks the files on the volume.

Important caveat
Here the reader is read-only only because Docker mounts the volume read-only. On real EFS
that flag is not what protects the data: IAM does (the reader role may mount but not
write, and the file-system policy explicitly denies it write). This test cannot check
IAM. The mutation test shows why it matters: remove the read-only flag and the reader
can write, because the shared folder is group-writable on purpose.

How to run
Only Docker is needed. Run tests/contract/run.sh. Exit 0 means pass, 1 means a check
failed, 2 means the build or start failed. It always deletes its containers and volume
at the end, and only touches things named sefs-contract.
Settings: MIN_READS (default 5), TIMEOUT_SECONDS (default 180).

What it checks
1. Writer started as 1001:1000 and reader as 1002:1000, both on /mnt/shared.
2. Reader logged exactly one write-probe line, and it says DENIED.
3. Writer logged no write errors.
4. At least 5 files written and read; every file the reader read has the same name and
   checksum the writer logged; no file read twice.
5. The files actually on the volume are exactly the ones the writer logged, with
   matching checksums.
6. Folder owned 1001:1000 with mode 775; every file owned 1001:1000 with mode 644
   (group can read); no leftover temp or probe file.
7. Writer stops cleanly on SIGTERM (exit code 0, logs WRITER_STOP).

Proof the checks are real
Change the reader's read_only: true to read_only: false in docker-compose.yml and run:
it fails, because the reader now logs WRITE_PROBE ALLOWED. Undo exactly that change and
run again: it passes.
