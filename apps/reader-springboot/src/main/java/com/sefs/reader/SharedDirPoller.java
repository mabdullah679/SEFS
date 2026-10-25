package com.sefs.reader;

import com.sun.security.auth.module.UnixSystem;
import jakarta.annotation.PostConstruct;
import java.io.IOException;
import java.io.OutputStream;
import java.nio.file.DirectoryStream;
import java.nio.file.FileAlreadyExistsException;
import java.nio.file.FileSystemException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.StandardOpenOption;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.util.ArrayList;
import java.util.Collections;
import java.util.HashSet;
import java.util.HexFormat;
import java.util.List;
import java.util.Set;
import java.util.concurrent.TimeUnit;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.scheduling.annotation.Scheduled;
import org.springframework.stereotype.Component;

/**
 * Contract (docs/CONTRACTS.md section 3, "apps (application code)"); these log lines are a
 * test interface, do not reword them:
 *   READER_START uid=&lt;uid&gt; gid=&lt;gid&gt; dir=&lt;dir&gt;
 *   WRITE_PROBE DENIED &lt;exception-class/errno&gt;   or   WRITE_PROBE ALLOWED
 *   READ &lt;filename&gt; sha256=&lt;hex&gt;
 * Never creates, modifies or deletes a data file. The only write it ever attempts is the
 * probe file, which it deletes again if the attempt unexpectedly succeeds.
 */
@Component
public class SharedDirPoller {

    static final String PROBE_NAME = ".reader-write-probe";
    private static final Logger log = LoggerFactory.getLogger(SharedDirPoller.class);

    private final Path sharedDir;
    private final Set<String> seen = Collections.synchronizedSet(new HashSet<>());

    public SharedDirPoller(@Value("${SHARED_DIR:/mnt/shared}") String sharedDir) {
        this.sharedDir = Path.of(sharedDir);
    }

    /** Runs before the scheduler starts, so READER_START and the probe come first. */
    @PostConstruct
    void start() {
        UnixSystem unix = new UnixSystem();
        log.info("READER_START uid={} gid={} dir={}", unix.getUid(), unix.getGid(), sharedDir);
        log.info(probeWrite());
    }

    @Scheduled(
            fixedDelayString = "${READER_POLL_SECONDS:5}",
            initialDelayString = "${READER_POLL_SECONDS:5}",
            timeUnit = TimeUnit.SECONDS)
    void poll() {
        if (log.isDebugEnabled()) {
            log.debug(probeWrite());
        }
        List<Path> candidates = new ArrayList<>();
        // Only "*.json", never dot-files: the writer's temp files are ".<name>.json.tmp".
        try (DirectoryStream<Path> ds = Files.newDirectoryStream(sharedDir, "*.json")) {
            for (Path p : ds) {
                String name = p.getFileName().toString();
                if (!name.startsWith(".") && Files.isRegularFile(p) && !seen.contains(name)) {
                    candidates.add(p);
                }
            }
        } catch (IOException e) {
            log.info("LIST_ERROR {} {}", e.getClass().getName(), e.getMessage());
            return;
        }
        candidates.sort(null); // filenames start with a UTC timestamp: oldest first
        for (Path p : candidates) {
            String name = p.getFileName().toString();
            try {
                byte[] bytes = Files.readAllBytes(p); // read-only open
                log.info("READ {} sha256={}", name, sha256(bytes));
                seen.add(name);
            } catch (IOException e) {
                // Not marked seen: retried next poll.
                log.info("READ_ERROR {} {} {}", name, e.getClass().getName(), e.getMessage());
            }
        }
    }

    /** Returns exactly "WRITE_PROBE DENIED <class>/<errno>" or "WRITE_PROBE ALLOWED". */
    String probeWrite() {
        Path probe = sharedDir.resolve(PROBE_NAME);
        try {
            try {
                Files.createFile(probe);
            } catch (FileAlreadyExistsException exists) {
                // O_CREAT|O_EXCL reports EEXIST before EROFS; a stale probe must not mask the
                // real answer, so try opening the existing one for write instead.
                try (OutputStream out = Files.newOutputStream(probe, StandardOpenOption.WRITE)) {
                    out.flush();
                }
            }
        } catch (IOException e) {
            return "WRITE_PROBE DENIED " + e.getClass().getSimpleName() + "/" + errnoName(e);
        }
        try {
            Files.deleteIfExists(probe);
        } catch (IOException e) {
            log.info("WRITE_PROBE_CLEANUP_FAILED {} {}", e.getClass().getName(), e.getMessage());
        }
        return "WRITE_PROBE ALLOWED";
    }

    static String errnoName(IOException e) {
        String reason = (e instanceof FileSystemException fse) ? fse.getReason() : e.getMessage();
        if (reason == null) {
            return "UNKNOWN";
        }
        return switch (reason) {
            case "Read-only file system" -> "EROFS";
            case "Permission denied" -> "EACCES";
            case "Operation not permitted" -> "EPERM";
            case "No such file or directory" -> "ENOENT";
            case "No space left on device" -> "ENOSPC";
            case "Disk quota exceeded" -> "EDQUOT";
            default -> reason.replace(' ', '_');
        };
    }

    static String sha256(byte[] bytes) {
        try {
            return HexFormat.of().formatHex(MessageDigest.getInstance("SHA-256").digest(bytes));
        } catch (NoSuchAlgorithmException e) {
            throw new IllegalStateException("SHA-256 missing from the JRE", e);
        }
    }
}
