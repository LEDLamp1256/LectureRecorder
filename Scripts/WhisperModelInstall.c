/* Closed developer preparation for large-v3-turbo; not an app/worker component.
 * Parent paths are traversed once from / using retained no-follow descriptors.
 * Only an anonymous, descriptor-verified temporary is cloned into the destination.
 * Security boundary: excludes a malicious same-UID process discovering/opening
 * or replacing the random basename between exclusive creation and immediate
 * unlink, and subsequent mutation through an FD acquired in that interval.
 * Also excludes modification after publication by an authorized directory writer.
 * Worker-side descriptor-backed verification remains authoritative for inference.
 */
#include <CommonCrypto/CommonDigest.h>
#include <errno.h>
#include <fcntl.h>
#include <pwd.h>
#include <signal.h>
#include <spawn.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/clonefile.h>
#include <sys/stat.h>
#include <sys/statvfs.h>
#include <sys/wait.h>
#include <unistd.h>

static const uint64_t model_bytes = UINT64_C(1624555275);
static const char model_hash[] = "1fc70f774d38eb169993ac391eea357ef47c88757ef72ee5943879b7e8e2bc69";
static const char model_name[] = "ggml-large-v3-turbo.bin";
static const char production_id[] = "com.dylanlee.LectureRecorder";
static const char harness_id[] = "com.dylanlee.LectureRecorder.WorkerLaunchHarness";
static const char model_url[] = "https://huggingface.co/ggerganov/whisper.cpp/resolve/5359861c739e955e79d9a303bcbc70fb988958b1/ggml-large-v3-turbo.bin";

struct directories { int fd[128]; size_t count; };
enum event { parent_opened, source_opened, anonymous_created, copied_block, verified, published, temporary_closing };
#ifdef LR_MODEL_INSTALL_TESTING
static void (*test_event)(enum event, int, const char *) = NULL;
static int test_clone_errno;
static int (*test_download)(pid_t *) = NULL;
#define OBSERVE(e, fd, name) do { if (test_event) test_event(e, fd, name); } while (0)
#else
#define OBSERVE(e, fd, name) ((void)0)
#endif

static int error(const char *what) {
    fprintf(stderr, "error: %s (%s)\n", what, strerror(errno));
    return -1;
}

static int retain(struct directories *dirs, int fd) {
    if (fd < 0) return -1;
    if (dirs->count == sizeof(dirs->fd) / sizeof(dirs->fd[0])) {
        close(fd); errno = ENAMETOOLONG; return -1;
    }
    dirs->fd[dirs->count++] = fd;
    return fd;
}

static int component(struct directories *dirs, int parent, const char *name, bool create) {
    if (!*name || strchr(name, '/') || !strcmp(name, ".") || !strcmp(name, "..")) {
        errno = EINVAL; return -1;
    }
    if (create && mkdirat(parent, name, 0700) < 0 && errno != EEXIST) return -1;
    int fd = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    if (fd < 0) return -1;
    struct stat st;
    if (fstat(fd, &st) < 0 || !S_ISDIR(st.st_mode)) {
        close(fd); errno = ENOTDIR; return -1;
    }
    if (retain(dirs, fd) < 0) return -1;
    OBSERVE(parent_opened, fd, name);
    return fd;
}

static int home_directory(struct directories *dirs, const char *home) {
    if (!home || home[0] != '/') { errno = EINVAL; return -1; }
    int fd = retain(dirs, open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC));
    char *path = strdup(home + 1), *cursor = NULL;
    if (fd < 0 || !path) { free(path); return -1; }
    for (char *part = strtok_r(path, "/", &cursor); part; part = strtok_r(NULL, "/", &cursor)) {
        fd = component(dirs, fd, part, false);
        if (fd < 0) break;
    }
    free(path);
    return fd;
}

static int model_directory(struct directories *dirs, int containers, bool harness, bool create) {
    const char *identifier = harness ? harness_id : production_id;
    const char *parts[] = { identifier, "Data", "Library",
        "Application Support", identifier, "Models", "Whisper", "large-v3-turbo", model_hash };
    int fd = containers;
    for (size_t i = 0; i < sizeof(parts) / sizeof(parts[0]); i++) {
        /* The production app-support boundary must already exist. Staging may
         * create the harness-specific root beneath its existing container. */
        fd = component(dirs, fd, parts[i], create && i >= (harness ? 4u : 5u));
        if (fd < 0) return -1;
    }
    return fd;
}

static int regular_file(int dir, const char *name) {
    int fd = openat(dir, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC);
    if (fd < 0) return -1;
    struct stat st;
    if (fstat(fd, &st) < 0 || !S_ISREG(st.st_mode)) {
        close(fd); errno = EINVAL; return -1;
    }
    return fd;
}

static int verify(int fd, uint64_t expected, const char *hash) {
    struct stat st;
    if (fstat(fd, &st) < 0 || !S_ISREG(st.st_mode) || st.st_size < 0 ||
        (uint64_t)st.st_size != expected) { errno = EINVAL; return -1; }
    CC_SHA256_CTX ctx;
    CC_SHA256_Init(&ctx);
    unsigned char bytes[65536], digest[CC_SHA256_DIGEST_LENGTH];
    uint64_t offset = 0;
    while (offset < expected) {
        size_t wanted = expected - offset < sizeof(bytes) ? (size_t)(expected - offset) : sizeof(bytes);
        ssize_t n = pread(fd, bytes, wanted, (off_t)offset);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) { errno = EIO; return -1; }
        CC_SHA256_Update(&ctx, bytes, (CC_LONG)n);
        offset += (uint64_t)n;
    }
    CC_SHA256_Final(digest, &ctx);
    char hex[65];
    for (size_t i = 0; i < sizeof(digest); i++) snprintf(hex + i * 2, 3, "%02x", digest[i]);
    if (strcmp(hex, hash) || fstat(fd, &st) < 0 || (uint64_t)st.st_size != expected) {
        errno = EINVAL; return -1;
    }
    return 0;
}

static int anonymous_file(int dir) {
    for (int attempt = 0; attempt < 8; attempt++) {
        unsigned char random[16]; char name[64] = ".whisper-model-";
        arc4random_buf(random, sizeof(random));
        for (size_t i = 0; i < sizeof(random); i++) snprintf(name + 15 + i * 2, 3, "%02x", random[i]);
        int fd = openat(dir, name, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0600);
        if (fd < 0) { if (errno == EEXIST) continue; return -1; }
        /* No hook, hashing, producer launch, or other work in this interval. */
        int unlinked = unlinkat(dir, name, 0);
        if (unlinked < 0) {
            int saved = errno; close(fd); errno = saved;
            fprintf(stderr, "error: could not anonymize temporary %s; no pathname cleanup attempted\n", name);
            return -1;
        }
        struct stat st;
        if (fstat(fd, &st) < 0 || !S_ISREG(st.st_mode) || st.st_nlink != 0) {
            close(fd); errno = EINVAL; return -1;
        }
        OBSERVE(anonymous_created, fd, name);
        return fd;
    }
    errno = EEXIST; return -1;
}

static int copy_bytes(int source, int temporary, uint64_t expected) {
    unsigned char buffer[65536]; uint64_t total = 0;
    for (;;) {
        ssize_t n = read(source, buffer, sizeof(buffer));
        if (n < 0 && errno == EINTR) continue;
        if (n < 0) return -1;
        if (!n) break;
        if ((uint64_t)n > expected - total) { errno = EFBIG; return -1; }
        for (ssize_t offset = 0; offset < n;) {
            ssize_t written = write(temporary, buffer + offset, (size_t)(n - offset));
            if (written < 0 && errno == EINTR) continue;
            if (written <= 0) { errno = EIO; return -1; }
            offset += written;
        }
        total += (uint64_t)n;
        OBSERVE(copied_block, source, NULL);
    }
    if (total != expected) { errno = EINVAL; return -1; }
    return 0;
}

static int publish(int temporary, int dir, uint64_t expected, const char *hash) {
    if (verify(temporary, expected, hash) < 0) return error("anonymous model size/SHA-256 mismatch; nothing published");
    if (fsync(temporary) < 0 || fcntl(temporary, F_FULLFSYNC) < 0) return error("temporary durability failed; nothing published");
    OBSERVE(verified, temporary, NULL);
    int rc;
#ifdef LR_MODEL_INSTALL_TESTING
    if (test_clone_errno) { errno = test_clone_errno; rc = -1; } else
#endif
    rc = fclonefileat(temporary, dir, model_name,
        CLONE_NOOWNERCOPY | CLONE_NOFOLLOW_ANY | CLONE_RESOLVE_BENEATH);
    if (rc < 0) return error("descriptor-source cloning failed; destination must be absent on the same clone-capable volume (APFS); no copy/rename fallback");
    OBSERVE(published, temporary, NULL);
    int fd = regular_file(dir, model_name);
    if (fd < 0) return error("published entry unavailable; publication may have succeeded; no deletion attempted");
    rc = verify(fd, expected, hash);
    if (!rc) rc = fsync(fd);
    if (!rc) rc = fcntl(fd, F_FULLFSYNC);
    int close_rc = close(fd);
    if (!rc) rc = close_rc;
    if (!rc) rc = fsync(dir);
    if (rc < 0) return error("published verification/durability uncertain; entry retained; worker re-verification required");
    return 0;
}

/* Called before temporary creation. The producer sees only the pipe, never
 * the temporary FD; every retained directory/source FD is close-on-exec. */
static int download(pid_t *pid) {
#ifdef LR_MODEL_INSTALL_TESTING
    if (test_download) return test_download(pid);
#endif
    int stream[2]; if (pipe(stream) < 0) return -1;
    if (fcntl(stream[0], F_SETFD, FD_CLOEXEC) < 0 || fcntl(stream[1], F_SETFD, FD_CLOEXEC) < 0) {
        int saved = errno; close(stream[0]); close(stream[1]); errno = saved; return -1;
    }
    posix_spawn_file_actions_t actions;
    int rc = posix_spawn_file_actions_init(&actions);
    if (rc) { close(stream[0]); close(stream[1]); errno = rc; return -1; }
    if (!rc) rc = posix_spawn_file_actions_adddup2(&actions, stream[1], STDOUT_FILENO);
    if (!rc) rc = posix_spawn_file_actions_addclose(&actions, stream[0]);
    if (!rc) rc = posix_spawn_file_actions_addclose(&actions, stream[1]);
    char *args[] = { "/usr/bin/curl", "-q", "--fail", "--location", "--proto", "=https",
        "--output", "-", (char *)model_url, NULL };
    extern char **environ;
    if (!rc) rc = posix_spawn(pid, args[0], &actions, NULL, args, environ);
    posix_spawn_file_actions_destroy(&actions);
    close(stream[1]);
    if (rc) { close(stream[0]); errno = rc; return -1; }
    return stream[0];
}

static int prepare_model(const char *home_path, bool stage, uint64_t expected, const char *hash) {
    struct directories dirs = {0};
    int result = -1, source = -1, temporary = -1; pid_t producer = -1;
    int home = home_directory(&dirs, home_path);
    int library = home < 0 ? -1 : component(&dirs, home, "Library", false);
    int containers = library < 0 ? -1 : component(&dirs, library, "Containers", false);
    int dest = containers < 0 ? -1 : model_directory(&dirs, containers, stage, true);
    if (dest < 0) { error("trusted model directory traversal failed; launch the app/harness once to create its container"); goto done; }
    struct stat existing;
    if (fstatat(dest, model_name, &existing, AT_SYMLINK_NOFOLLOW) == 0) {
        source = regular_file(dest, model_name);
        result = source < 0 ? -1 : verify(source, expected, hash);
        if (result < 0) error("existing destination conflicts; it was not changed");
        else puts("Verified existing large-v3-turbo model; no overwrite.");
        goto done;
    }
    if (errno != ENOENT) { error("destination inspection failed"); goto done; }
    struct statvfs space;
    uint64_t required = stage ? expected : UINT64_C(10) * 1024 * 1024 * 1024;
    if (fstatvfs(dest, &space) < 0 || (long double)space.f_bavail * space.f_frsize < required) {
        errno = ENOSPC; error("insufficient free space for model preparation"); goto done;
    }
    if (stage) {
        int srcdir = model_directory(&dirs, containers, false, false);
        source = srcdir < 0 ? -1 : regular_file(srcdir, model_name);
    } else source = download(&producer);
    if (source < 0) { error("model source/producer unavailable"); goto done; }
    OBSERVE(source_opened, source, NULL);
    temporary = anonymous_file(dest);
    if (temporary < 0) { error("exclusive anonymous temporary creation failed"); goto done; }
    result = copy_bytes(source, temporary, expected);
    if (result < 0) error("model input failed or had the wrong byte count; nothing published");
    close(source); source = -1;
    if (producer > 0) {
        if (result < 0) kill(producer, SIGTERM);
        int status = 0; pid_t waited;
        do { waited = waitpid(producer, &status, 0); } while (waited < 0 && errno == EINTR);
        producer = -1;
        if (waited < 0 || !WIFEXITED(status) || WEXITSTATUS(status) != 0) {
            result = -1; errno = EIO; error("download producer failed; nothing published");
        }
    }
    if (!result) result = publish(temporary, dest, expected, hash);
    if (!result) puts("Installed verified large-v3-turbo model via descriptor-source APFS clone.");
done:
    if (source >= 0) close(source);
    if (temporary >= 0) { OBSERVE(temporary_closing, temporary, NULL); close(temporary); }
    if (producer > 0) { kill(producer, SIGTERM); while (waitpid(producer, NULL, 0) < 0 && errno == EINTR) {} }
    while (dirs.count) close(dirs.fd[--dirs.count]);
    return result ? 1 : 0;
}

#ifndef LR_MODEL_INSTALL_TESTING
int main(int argc, char **argv) {
    if (argc != 2 || (strcmp(argv[1], "install") && strcmp(argv[1], "stage"))) {
        fprintf(stderr, "error: expected closed install or stage operation\n"); return 1;
    }
    struct passwd *account = getpwuid(getuid());
    return prepare_model(account ? account->pw_dir : NULL, !strcmp(argv[1], "stage"), model_bytes, model_hash);
}
#endif
