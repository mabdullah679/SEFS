# SEFS writer. Host needs only Docker; Python lives in the image.
FROM python:3.12-slim

ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    SHARED_DIR=/mnt/shared \
    WRITER_INTERVAL_SECONDS=5

WORKDIR /app
COPY writer.py /app/writer.py

# Mount point owned like the EFS access point root (creation_info 1001:1000, 0775),
# so a fresh local named volume starts with the same ownership.
RUN mkdir -p /mnt/shared && chown 1001:1000 /mnt/shared && chmod 0775 /mnt/shared

# Same identity the writer access point forces (posix_user 1001:1000).
USER 1001:1000

# exec form: python is PID 1 and receives SIGTERM directly.
ENTRYPOINT ["python", "-u", "/app/writer.py"]
