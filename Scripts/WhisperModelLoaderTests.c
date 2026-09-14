#include "WhisperBridge.h"
#include <CommonCrypto/CommonDigest.h>
#include <assert.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

static void digest_hex(const unsigned char * bytes, size_t count, char output[65]) {
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(bytes, (CC_LONG) count, digest);
    static const char digits[] = "0123456789abcdef";
    for (size_t index = 0; index < sizeof(digest); ++index) {
        output[index * 2] = digits[digest[index] >> 4];
        output[index * 2 + 1] = digits[digest[index] & 0x0f];
    }
    output[64] = '\0';
}

static void write_exact(const char * path, const unsigned char * bytes, size_t count) {
    int fd = open(path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0600);
    assert(fd >= 0);
    assert(write(fd, bytes, count) == (ssize_t) count);
    assert(close(fd) == 0);
}

int main(int argc, char ** argv) {
    assert(argc == 2);
    const char * root = argv[1];
    const unsigned char old_bytes[] = "BAD!old-verified-model";
    const unsigned char new_bytes[] = "BAD!new-pathname-model";
    assert(sizeof(old_bytes) == sizeof(new_bytes));
    char old_digest[65];
    digest_hex(old_bytes, sizeof(old_bytes), old_digest);

    char path[1024];
    snprintf(path, sizeof(path), "%s/model.bin", root);
    write_exact(path, old_bytes, sizeof(old_bytes));

    struct LRWhisperModelReport report;
    LRWhisperVerifiedModel model = lr_whisper_model_open_verified_for_testing(
        path, sizeof(old_bytes), old_digest, &report
    );
    assert(model != NULL);
    assert(report.status == LR_WHISPER_MODEL_OK);
    assert(report.bytes_hashed == sizeof(old_bytes));
    assert(report.descriptor_close_calls == 0);

    char replacement[1024];
    snprintf(replacement, sizeof(replacement), "%s/replacement.bin", root);
    write_exact(replacement, new_bytes, sizeof(new_bytes));
    assert(rename(replacement, path) == 0);

    LRWhisperContext context = lr_whisper_model_initialize(model, &report);
    assert(context == NULL);
    assert(report.status == LR_WHISPER_MODEL_MUTATED);
    assert(report.loader_read_calls > 0);
    assert(report.bytes_loaded > 0);
    assert(report.loader_close_calls == 1);
    assert(report.descriptor_close_calls == 1);
    assert(report.first_loaded_byte_count == 4);
    assert(memcmp(report.first_loaded_bytes, old_bytes, 4) == 0);

    char current[sizeof(new_bytes)];
    int current_fd = open(path, O_RDONLY | O_CLOEXEC);
    assert(current_fd >= 0);
    assert(read(current_fd, current, sizeof(current)) == sizeof(current));
    assert(memcmp(current, new_bytes, sizeof(new_bytes)) == 0);
    assert(close(current_fd) == 0);

    unlink(path);
    write_exact(path, old_bytes, sizeof(old_bytes));
    model = lr_whisper_model_open_verified_for_testing(path, sizeof(old_bytes), old_digest, &report);
    assert(model != NULL);
    context = lr_whisper_model_initialize(model, &report);
    assert(context == NULL);
    assert(report.status == LR_WHISPER_MODEL_INITIALIZATION_FAILED);
    assert(report.loader_read_calls > 0);
    assert(report.loader_close_calls == 1);
    assert(report.descriptor_close_calls == 1);

    unlink(path);
    write_exact(path, new_bytes, sizeof(new_bytes));
    model = lr_whisper_model_open_verified_for_testing(path, sizeof(new_bytes), old_digest, &report);
    assert(model == NULL);
    assert(report.status == LR_WHISPER_MODEL_DIGEST_MISMATCH);
    assert(report.descriptor_close_calls == 1);

    model = lr_whisper_model_open_verified_for_testing(path, sizeof(new_bytes) + 1, old_digest, &report);
    assert(model == NULL);
    assert(report.status == LR_WHISPER_MODEL_SIZE_MISMATCH);
    assert(report.descriptor_close_calls == 1);

    char directory_path[1024];
    snprintf(directory_path, sizeof(directory_path), "%s/directory", root);
    assert(mkdir(directory_path, 0700) == 0);
    model = lr_whisper_model_open_verified_for_testing(directory_path, 0, old_digest, &report);
    assert(model == NULL);
    assert(report.status == LR_WHISPER_MODEL_NOT_REGULAR);
    assert(report.descriptor_close_calls == 1);

    char symlink_path[1024];
    snprintf(symlink_path, sizeof(symlink_path), "%s/model-link", root);
    assert(symlink(path, symlink_path) == 0);
    model = lr_whisper_model_open_verified_for_testing(symlink_path, sizeof(new_bytes), old_digest, &report);
    assert(model == NULL);
    assert(report.status == LR_WHISPER_MODEL_OPEN_FAILED);
    assert(report.descriptor_close_calls == 0);

    char missing_path[1024];
    snprintf(missing_path, sizeof(missing_path), "%s/missing", root);
    model = lr_whisper_model_open_verified_for_testing(missing_path, 0, old_digest, &report);
    assert(model == NULL);
    assert(report.status == LR_WHISPER_MODEL_OPEN_FAILED);
    assert(report.descriptor_close_calls == 0);

    unlink(path);
    write_exact(path, old_bytes, sizeof(old_bytes));
    model = lr_whisper_model_open_verified_for_testing(path, sizeof(old_bytes), old_digest, &report);
    assert(model != NULL);
    lr_whisper_model_discard(model, &report);
    assert(report.loader_close_calls == 0);
    assert(report.descriptor_close_calls == 1);

    assert(lr_whisper_configuration_is_expected() == 1);
    printf("descriptor loader scenarios passed: open, symlink/type, size, digest, rewind, raced pathname, callback read, initialization failure, exact-once close, fixed params\n");
    return 0;
}
