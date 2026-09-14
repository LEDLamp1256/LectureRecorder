#define LR_MODEL_INSTALL_TESTING 1
#include "WhisperModelInstall.c"
#include <assert.h>
#include <dirent.h>
#include <limits.h>

static unsigned char good[131072];
static char good_hash[65], root[PATH_MAX], home_path[PATH_MAX], source_path[PATH_MAX], dest_path[PATH_MAX];
static char target[PATH_MAX], moved[PATH_MAX], outside[PATH_MAX];
static char anonymous_name[64], reused_path[PATH_MAX];
static int cases, fired, temp_fd, temp_count, producer_status, input_delta;
static int retained_dest;
static struct stat anonymous_identity, source_identity, competitor_identity;
static bool staging;
enum attack { none, swap_parent, replace_source, replace_during_copy, mutate_source, conflict, clone_cow, reuse_before_verify, reuse_after_verify };
static enum attack attack;

static void join(char *out, const char *a, const char *b) {
    assert(strlen(a) + strlen(b) + 2 < PATH_MAX);
    strcpy(out, a); strcat(out, "/"); strcat(out, b);
}
static void mkdirs(const char *path) {
    char copy[PATH_MAX]; strcpy(copy, path);
    for (char *p = copy + 1; ; p++) {
        if (*p == '/' || !*p) {
            char c = *p; *p = 0;
            assert(mkdir(copy, 0700) == 0 || errno == EEXIST);
            *p = c; if (!c) break;
        }
    }
}
static void write_file(const char *path, const void *data, size_t count) {
    int fd = open(path, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0600);
    assert(fd >= 0);
    size_t offset = 0;
    while (offset < count) { ssize_t n = write(fd, (const char *)data + offset, count - offset); assert(n > 0); offset += (size_t)n; }
    assert(close(fd) == 0);
}
static void check_bytes(const char *path, const void *data, size_t count) {
    int fd = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC); assert(fd >= 0);
    struct stat st; assert(fstat(fd, &st) == 0 && st.st_size == (off_t)count);
    unsigned char bytes[sizeof(good) + 1]; assert(count <= sizeof(bytes));
    assert(read(fd, bytes, sizeof(bytes)) == (ssize_t)count);
    assert(!memcmp(bytes, data, count)); assert(close(fd) == 0);
}
static bool absent(const char *path) { struct stat st; return lstat(path, &st) < 0 && errno == ENOENT; }
static int pipe_producer(pid_t *pid) {
    int ends[2]; assert(pipe(ends) == 0);
    *pid = fork(); assert(*pid >= 0);
    if (!*pid) {
        close(ends[0]);
        size_t length = sizeof(good) + input_delta, offset = 0;
        while (offset < length) {
            unsigned char bytes[4096]; memset(bytes, good[0], sizeof(bytes));
            size_t count = length - offset < sizeof(bytes) ? length - offset : sizeof(bytes);
            ssize_t n = write(ends[1], bytes, count); if (n <= 0) _exit(3); offset += (size_t)n;
        }
        close(ends[1]); _exit(producer_status);
    }
    close(ends[1]); return ends[0];
}
static void hook(enum event e, int fd, const char *name) {
    if (e == parent_opened && !strcmp(name, model_hash) && retained_dest < 0) retained_dest = fd;
    if (e == source_opened && staging) assert(fstat(fd, &source_identity) == 0);
    if (e == copied_block && staging) {
        struct stat now; assert(fstat(fd, &now) == 0);
        assert(now.st_dev == source_identity.st_dev && now.st_ino == source_identity.st_ino);
    }
    if (e == anonymous_created) {
        struct stat st; assert(fstat(fd, &st) == 0 && st.st_nlink == 0 && S_ISREG(st.st_mode));
        assert((st.st_mode & 0777) == 0600 && (fcntl(fd, F_GETFD) & FD_CLOEXEC));
        assert(!strncmp(name, ".whisper-model-", 15)); temp_count++;
        strcpy(anonymous_name, name);
        anonymous_identity = st;
    }
    if (e == verified || e == published || e == temporary_closing) {
        struct stat now; assert(fstat(fd, &now) == 0 && now.st_nlink == 0);
        assert(now.st_dev == anonymous_identity.st_dev && now.st_ino == anonymous_identity.st_ino);
    }
    if (e == verified) assert(verify(fd, sizeof(good), good_hash) == 0);
    if (e == published) {
        struct stat anonymous, clone;
        int entry = regular_file(retained_dest, model_name); assert(entry >= 0);
        assert(fstat(fd, &anonymous) == 0 && fstat(entry, &clone) == 0);
        assert(anonymous.st_dev == clone.st_dev && anonymous.st_ino != clone.st_ino);
        assert(verify(entry, sizeof(good), good_hash) == 0); close(entry);
    }
    if (e == temporary_closing) { struct stat st; assert(fstat(fd, &st) == 0 && st.st_nlink == 0); temp_fd = fd; }
    if (fired) return;
    if ((attack == reuse_before_verify && e == anonymous_created) ||
        (attack == reuse_after_verify && e == verified)) {
        strcpy(reused_path, dest_path); *strrchr(reused_path, '/') = 0;
        strcat(reused_path, "/"); strcat(reused_path, anonymous_name);
        write_file(reused_path, "unrelated", 9); fired++;
    } else if (attack == swap_parent && e == parent_opened) {
        char path[PATH_MAX]; assert(fcntl(fd, F_GETPATH, path) == 0);
        if (strcmp(path, target)) return;
        assert(rename(target, moved) == 0);
        assert(symlink(outside, target) == 0); fired++;
    } else if ((attack == replace_source && e == source_opened) ||
               (attack == replace_during_copy && e == copied_block)) {
        assert(rename(source_path, moved) == 0);
        assert(symlink(outside, source_path) == 0); fired++;
    } else if (attack == mutate_source && e == copied_block) {
        int writer = open(source_path, O_WRONLY | O_NOFOLLOW); assert(writer >= 0);
        unsigned char wrong = 0;
        assert(pwrite(writer, &wrong, 1, 65536) == 1); close(writer); fired++;
    } else if (attack == conflict && e == verified) {
        write_file(dest_path, "competitor", 10); assert(lstat(dest_path, &competitor_identity) == 0); fired++;
    } else if (attack == clone_cow && e == published) {
        unsigned char wrong = 0; assert(pwrite(fd, &wrong, 1, 0) == 1); fired++;
    }
}
static void check_tree(const char *path) {
    DIR *dir = opendir(path); assert(dir);
    struct dirent *entry;
    while ((entry = readdir(dir))) {
        if (!strcmp(entry->d_name, ".") || !strcmp(entry->d_name, "..")) continue;
        char child[PATH_MAX]; join(child, path, entry->d_name);
        assert(strncmp(entry->d_name, ".whisper-model-", 15) || !strcmp(entry->d_name, ".whisper-model-preserve") || !strcmp(child, reused_path));
        struct stat st; assert(lstat(child, &st) == 0);
        if (S_ISDIR(st.st_mode)) check_tree(child);
    }
    closedir(dir);
}
static void fixture(void) {
    cases++; fired = temp_count = producer_status = input_delta = 0; temp_fd = retained_dest = -1;
    attack = none; test_clone_errno = 0; test_event = NULL;
    reused_path[0] = target[0] = 0;
    char case_name[64], case_path[PATH_MAX]; snprintf(case_name, sizeof(case_name), "case-%03d", cases);
    join(case_path, root, case_name); join(home_path, case_path, "home ; $(literal)");
    for (int harness = 0; harness < 2; harness++) {
        char suffix[1024], path[PATH_MAX];
        const char *id = harness ? harness_id : production_id;
        snprintf(suffix, sizeof(suffix), "Library/Containers/%s/Data/Library/Application Support/%s/Models/Whisper/large-v3-turbo/%s", id, id, model_hash);
        join(path, home_path, suffix); mkdirs(path);
        if (harness) join(dest_path, path, model_name); else join(source_path, path, model_name);
    }
    if (!staging) strcpy(dest_path, source_path);
    if (staging) write_file(source_path, good, sizeof(good));
    join(outside, case_path, "outside"); mkdirs(outside);
    join(moved, case_path, "retained-original");
    char sentinel_path[PATH_MAX]; join(sentinel_path, home_path, ".whisper-model-preserve");
    write_file(sentinel_path, "preserve", 8);
    test_event = hook;
}
static void run_case(const char *label, int expected, const char *hash) {
    int result = prepare_model(home_path, staging, sizeof(good), hash);
    assert(result == expected);
    if (temp_fd >= 0) { errno = 0; assert(fcntl(temp_fd, F_GETFD) < 0 && errno == EBADF); }
    if (*reused_path) check_bytes(reused_path, "unrelated", 9);
    if (attack == conflict && fired) {
        struct stat now; assert(lstat(dest_path, &now) == 0);
        assert(now.st_dev == competitor_identity.st_dev && now.st_ino == competitor_identity.st_ino);
    }
    char case_path[PATH_MAX]; strcpy(case_path, home_path); *strrchr(case_path, '/') = 0;
    check_tree(case_path);
    char sentinel[PATH_MAX];
    join(sentinel, (attack == swap_parent && fired && !strcmp(target, home_path)) ||
        (!absent(moved) && !strcmp(target, home_path) && attack == none) ? moved : home_path,
        ".whisper-model-preserve");
    check_bytes(sentinel, "preserve", 8);
    printf("PASS %s %03d: %s (anonymous=%d)\n", staging ? "stage" : "install", cases, label, temp_count);
}

int main(int argc, char **argv) {
    assert(argc == 2); staging = !strcmp(argv[1], "stage");
    assert(staging || !strcmp(argv[1], "install"));
    strcpy(root, "/private/tmp/LectureRecorder-model-security.XXXXXX"); assert(mkdtemp(root));
    printf("security test evidence: %s\n", root);
    memset(good, 'v', sizeof(good)); unsigned char digest[32]; CC_SHA256(good, sizeof(good), digest);
    for (int i = 0; i < 32; i++) snprintf(good_hash + i * 2, 3, "%02x", digest[i]);
    test_download = pipe_producer;
    assert(model_bytes == UINT64_C(1624555275));

    fixture(); run_case("valid exact bytes", 0, good_hash); check_bytes(dest_path, good, sizeof(good));
    int before = cases; run_case("existing valid destination reuse", 0, good_hash); assert(cases == before);
    fixture(); write_file(dest_path, "existing", 8);
    struct stat before_entry, after_entry; assert(lstat(dest_path, &before_entry) == 0);
    run_case("existing conflict", 1, good_hash); check_bytes(dest_path, "existing", 8);
    assert(lstat(dest_path, &after_entry) == 0 && before_entry.st_ino == after_entry.st_ino);
    fixture(); assert(symlink(outside, dest_path) == 0); assert(lstat(dest_path, &before_entry) == 0);
    run_case("destination symlink", 1, good_hash);
    assert(lstat(dest_path, &after_entry) == 0 && S_ISLNK(after_entry.st_mode) && before_entry.st_ino == after_entry.st_ino);
    fixture(); attack = conflict; run_case("competitor immediately before clone", 1, good_hash); assert(fired); check_bytes(dest_path, "competitor", 10);
    fixture(); run_case("wrong SHA-256", 1, "0000000000000000000000000000000000000000000000000000000000000000"); assert(absent(dest_path));
    for (int code = 0; code < 2; code++) {
        fixture(); test_clone_errno = code ? EXDEV : ENOTSUP;
        run_case(code ? "cross-filesystem fails closed" : "unsupported cloning fails closed", 1, good_hash); assert(absent(dest_path));
    }
    fixture(); attack = clone_cow; run_case("APFS clone retains verified bytes after source write", 0, good_hash);
    assert(fired); check_bytes(dest_path, good, sizeof(good));
    for (int after = 0; after < 2; after++) {
        fixture(); attack = after ? reuse_after_verify : reuse_before_verify;
        run_case(after ? "unlinked basename reused after verification" : "unlinked basename reused before verification", 0, good_hash);
        assert(fired); check_bytes(dest_path, good, sizeof(good));
    }
    if (staging) {
        fixture(); attack = replace_source; run_case("source replacement after open", 0, good_hash); assert(fired); check_bytes(dest_path, good, sizeof(good));
        fixture(); attack = replace_during_copy; run_case("source replacement during copy", 0, good_hash); assert(fired); check_bytes(dest_path, good, sizeof(good));
        fixture(); attack = mutate_source; run_case("source mutation during copy rejected", 1, good_hash); assert(fired && absent(dest_path));
        fixture(); assert(rename(source_path, moved) == 0 && symlink(moved, source_path) == 0);
        run_case("source symlink rejected", 1, good_hash); assert(absent(dest_path)); check_bytes(moved, good, sizeof(good));
    }
    for (int delta = -1; delta <= 1; delta += 2) {
        fixture();
        if (staging) { int fd = open(source_path, O_WRONLY); assert(fd >= 0); assert(ftruncate(fd, sizeof(good) + delta) == 0); close(fd); }
        else input_delta = delta;
        run_case(delta < 0 ? "truncated input" : "oversized input", 1, good_hash); assert(absent(dest_path));
    }
    if (!staging) { fixture(); producer_status = 7; run_case("producer fails after all expected bytes", 1, good_hash); assert(absent(dest_path)); }

    /* Every controlled parent from the test home through model digest. The
     * system /private/tmp anchor is not changed by the tests. Each successful
     * open is a deterministic substitution boundary, before further use. */
    for (int source_side = 0; source_side <= (staging ? 1 : 0); source_side++) {
        for (int level = 0; level < 12; level++) {
            fixture();
            const char *full = source_side ? source_path : dest_path;
            strcpy(target, home_path);
            const char *p = full + strlen(home_path);
            for (int i = 0; i < level; i++) {
                assert(*p == '/'); const char *end = strchr(p + 1, '/'); assert(end);
                strncat(target, p, (size_t)(end - p)); p = end;
            }
            char redirected_result[PATH_MAX]; strcpy(redirected_result, moved);
            const char *dest_suffix = dest_path + strlen(target);
            if (!source_side || level <= 2) strcat(redirected_result, dest_suffix);
            attack = swap_parent; run_case(source_side ? "source parent swap" : "destination parent swap", 0, good_hash); assert(fired);
            check_bytes((!source_side || level <= 2) ? redirected_result : dest_path, good, sizeof(good));
            DIR *empty = opendir(outside); assert(empty); int children = 0; struct dirent *e;
            while ((e = readdir(empty))) if (strcmp(e->d_name, ".") && strcmp(e->d_name, "..")) children++;
            closedir(empty); assert(children == 0);
        }
        for (int level = 0; level < 12; level++) {
            for (int type = 0; type < 2; type++) {
                fixture(); const char *full = source_side ? source_path : dest_path;
                strcpy(target, home_path); const char *p = full + strlen(home_path);
                for (int i = 0; i < level; i++) { const char *end = strchr(p + 1, '/'); assert(end); strncat(target, p, (size_t)(end - p)); p = end; }
                assert(rename(target, moved) == 0);
                if (type) write_file(target, "not-directory", 13); else assert(symlink(outside, target) == 0);
                run_case(type ? "parent regular file rejected" : "parent symlink rejected", 1, good_hash);
            }
        }
    }
    printf("security tests executed=%d passed=%d failed=0 skipped=0\n", cases + 1, cases + 1);
    return 0;
}
