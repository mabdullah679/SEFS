# SEFS reader. Multi-stage: Maven + JDK only in the build stage, so the host needs
# Docker and nothing else.
# Build stage runs on the BUILDER's native platform: Java bytecode is portable, so Maven
# never runs under QEMU when an x86 runner builds the arm64 image (CI was > 40 min).
FROM --platform=$BUILDPLATFORM maven:3-eclipse-temurin-21 AS build
WORKDIR /build
COPY pom.xml .
RUN mvn -B -q dependency:go-offline
COPY src ./src
RUN mvn -B -q -DskipTests package && cp target/reader.jar /build/reader.jar

FROM eclipse-temurin:21-jre
ENV SHARED_DIR=/mnt/shared \
    READER_POLL_SECONDS=5 \
    JAVA_TOOL_OPTIONS="-XX:MaxRAMPercentage=75"
WORKDIR /app
COPY --from=build /build/reader.jar /app/reader.jar
# The reader image never initialises the volume (compose mounts it with nocopy; on EFS
# the access point owns the root), so this mount point is just a placeholder.
RUN mkdir -p /mnt/shared
# Same identity the reader access point forces (posix_user 1002:1000).
USER 1002:1000
ENTRYPOINT ["java", "-jar", "/app/reader.jar"]
