#include "WhisperBridge.h"
#include "whisper.h"
#include <CommonCrypto/CommonDigest.h>
#include <errno.h>
#include <fcntl.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#define LR_MODEL_SIZE UINT64_C(1624555275)
#define LR_MODEL_SHA256 "1fc70f774d38eb169993ac391eea357ef47c88757ef72ee5943879b7e8e2bc69"

struct lr_verified_model {
    int fd;
    uint64_t expected_size;
    struct stat before;
};

struct lr_loader_context {
    struct lr_verified_model * model;
    struct LRWhisperModelReport * report;
    bool read_failed;
};

static void discard_log(enum ggml_log_level level, const char * text, void * user_data) {
    (void) level;
    (void) text;
    (void) user_data;
}

static struct whisper_context_params context_params(void) {
    whisper_log_set(discard_log, NULL);
    struct whisper_context_params params = whisper_context_default_params();
    params.use_gpu = false;
    params.flash_attn = false;
    params.gpu_device = 0;
    params.dtw_token_timestamps = false;
    params.dtw_aheads_preset = WHISPER_AHEADS_NONE;
    params.dtw_n_top = 0;
    params.dtw_aheads.n_heads = 0;
    params.dtw_aheads.heads = NULL;
    params.dtw_mem_size = 0;
    return params;
}

static void reset_report(struct LRWhisperModelReport * report) {
    if (report != NULL) {
        memset(report, 0, sizeof(*report));
        report->status = LR_WHISPER_MODEL_OK;
    }
}

static void set_status(struct LRWhisperModelReport * report, enum LRWhisperModelStatus status) {
    if (report != NULL) report->status = status;
}

static bool same_metadata(const struct stat * before, const struct stat * after) {
    return before->st_dev == after->st_dev &&
        before->st_ino == after->st_ino &&
        before->st_mode == after->st_mode &&
        before->st_size == after->st_size &&
        before->st_mtimespec.tv_sec == after->st_mtimespec.tv_sec &&
        before->st_mtimespec.tv_nsec == after->st_mtimespec.tv_nsec &&
        before->st_ctimespec.tv_sec == after->st_ctimespec.tv_sec &&
        before->st_ctimespec.tv_nsec == after->st_ctimespec.tv_nsec;
}

static bool close_descriptor(struct lr_verified_model * model, struct LRWhisperModelReport * report) {
    if (model->fd < 0) return true;
    int result = close(model->fd);
    model->fd = -1;
    if (report != NULL) report->descriptor_close_calls += 1;
    return result == 0;
}

static struct lr_verified_model * open_verified(
    const char * model_path,
    uint64_t expected_size,
    const char * expected_sha256,
    struct LRWhisperModelReport * report
) {
    reset_report(report);
    if (model_path == NULL || expected_sha256 == NULL) {
        set_status(report, LR_WHISPER_MODEL_OPEN_FAILED);
        return NULL;
    }
    const int fd = open(model_path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC);
    if (fd < 0) {
        set_status(report, LR_WHISPER_MODEL_OPEN_FAILED);
        return NULL;
    }
    struct lr_verified_model * model = calloc(1, sizeof(*model));
    if (model == NULL) {
        close(fd);
        if (report != NULL) report->descriptor_close_calls = 1;
        set_status(report, LR_WHISPER_MODEL_OPEN_FAILED);
        return NULL;
    }
    model->fd = fd;
    model->expected_size = expected_size;
    if (fstat(fd, &model->before) != 0 || !S_ISREG(model->before.st_mode)) {
        set_status(report, LR_WHISPER_MODEL_NOT_REGULAR);
        close_descriptor(model, report);
        free(model);
        return NULL;
    }
    if (model->before.st_size < 0 || (uint64_t) model->before.st_size != expected_size) {
        set_status(report, LR_WHISPER_MODEL_SIZE_MISMATCH);
        close_descriptor(model, report);
        free(model);
        return NULL;
    }

    CC_SHA256_CTX hash;
    CC_SHA256_Init(&hash);
    unsigned char buffer[1024 * 1024];
    uint64_t total = 0;
    while (true) {
        ssize_t count;
        do {
            count = read(fd, buffer, sizeof(buffer));
        } while (count < 0 && errno == EINTR);
        if (count < 0) {
            set_status(report, LR_WHISPER_MODEL_DIGEST_MISMATCH);
            close_descriptor(model, report);
            free(model);
            return NULL;
        }
        if (count == 0) break;
        CC_SHA256_Update(&hash, buffer, (CC_LONG) count);
        total += (uint64_t) count;
        if (report != NULL) report->bytes_hashed = total;
        if (total > expected_size) break;
    }
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256_Final(digest, &hash);
    char digest_hex[CC_SHA256_DIGEST_LENGTH * 2 + 1];
    static const char digits[] = "0123456789abcdef";
    for (size_t index = 0; index < CC_SHA256_DIGEST_LENGTH; ++index) {
        digest_hex[index * 2] = digits[digest[index] >> 4];
        digest_hex[index * 2 + 1] = digits[digest[index] & 0x0f];
    }
    digest_hex[sizeof(digest_hex) - 1] = '\0';
    if (total != expected_size || strcmp(digest_hex, expected_sha256) != 0) {
        set_status(report, LR_WHISPER_MODEL_DIGEST_MISMATCH);
        close_descriptor(model, report);
        free(model);
        return NULL;
    }
    if (lseek(fd, 0, SEEK_SET) != 0) {
        set_status(report, LR_WHISPER_MODEL_REWIND_FAILED);
        close_descriptor(model, report);
        free(model);
        return NULL;
    }
    return model;
}

LRWhisperVerifiedModel lr_whisper_model_open_verified(
    const char * model_path,
    struct LRWhisperModelReport * report
) {
    return open_verified(model_path, LR_MODEL_SIZE, LR_MODEL_SHA256, report);
}

#if defined(LR_WHISPER_TESTING)
LRWhisperVerifiedModel lr_whisper_model_open_verified_for_testing(
    const char * model_path,
    uint64_t expected_size,
    const char * expected_sha256,
    struct LRWhisperModelReport * report
) {
    return open_verified(model_path, expected_size, expected_sha256, report);
}
#endif

static size_t loader_read(void * context, void * output, size_t requested) {
    struct lr_loader_context * loader = context;
    size_t total = 0;
    while (total < requested) {
        ssize_t count;
        do {
            count = read(loader->model->fd, (unsigned char *) output + total, requested - total);
        } while (count < 0 && errno == EINTR);
        if (count < 0) {
            loader->read_failed = true;
            break;
        }
        if (count == 0) break;
        if (loader->report != NULL && loader->report->first_loaded_byte_count < 8) {
            uint32_t available = 8 - loader->report->first_loaded_byte_count;
            uint32_t copied = (uint32_t) count < available ? (uint32_t) count : available;
            memcpy(
                loader->report->first_loaded_bytes + loader->report->first_loaded_byte_count,
                (unsigned char *) output + total,
                copied
            );
            loader->report->first_loaded_byte_count += copied;
        }
        total += (size_t) count;
    }
    if (loader->report != NULL) {
        loader->report->loader_read_calls += 1;
        loader->report->bytes_loaded += total;
    }
    return total;
}

static bool loader_eof(void * context) {
    struct lr_loader_context * loader = context;
    off_t position = lseek(loader->model->fd, 0, SEEK_CUR);
    return loader->read_failed || position < 0 || (uint64_t) position >= loader->model->expected_size;
}

static void loader_close(void * context) {
    struct lr_loader_context * loader = context;
    if (loader->report != NULL) loader->report->loader_close_calls += 1;
}

LRWhisperContext lr_whisper_model_initialize(
    LRWhisperVerifiedModel opaque_model,
    struct LRWhisperModelReport * report
) {
    struct lr_verified_model * model = opaque_model;
    if (model == NULL) {
        set_status(report, LR_WHISPER_MODEL_INITIALIZATION_FAILED);
        return NULL;
    }
    struct lr_loader_context loader_context = { model, report, false };
    whisper_model_loader loader = {
        .context = &loader_context,
        .read = loader_read,
        .eof = loader_eof,
        .close = loader_close,
    };
    struct whisper_context * context = whisper_init_with_params(&loader, context_params());
    struct stat after;
    bool unchanged = fstat(model->fd, &after) == 0 && same_metadata(&model->before, &after);
    bool callback_valid = !loader_context.read_failed && report != NULL &&
        report->loader_close_calls == 1 &&
        (context == NULL || report->bytes_loaded == model->expected_size);
    bool close_ok = close_descriptor(model, report);
    free(model);

    if (!callback_valid || !unchanged) {
        if (context != NULL) whisper_free(context);
        set_status(report, LR_WHISPER_MODEL_MUTATED);
        return NULL;
    }
    if (!close_ok) {
        if (context != NULL) whisper_free(context);
        set_status(report, LR_WHISPER_MODEL_CLOSE_FAILED);
        return NULL;
    }
    if (context == NULL) {
        set_status(report, LR_WHISPER_MODEL_INITIALIZATION_FAILED);
        return NULL;
    }
    set_status(report, LR_WHISPER_MODEL_OK);
    return context;
}

void lr_whisper_model_discard(
    LRWhisperVerifiedModel opaque_model,
    struct LRWhisperModelReport * report
) {
    struct lr_verified_model * model = opaque_model;
    if (model == NULL) return;
    if (!close_descriptor(model, report)) set_status(report, LR_WHISPER_MODEL_CLOSE_FAILED);
    free(model);
}

void lr_whisper_destroy(LRWhisperContext context) {
    if (context != NULL) whisper_free((struct whisper_context *) context);
}

static struct whisper_full_params full_params(void) {
    struct whisper_full_params p = whisper_full_default_params(WHISPER_SAMPLING_GREEDY);
    p.strategy = WHISPER_SAMPLING_GREEDY;
    p.n_threads = 4;
    p.n_max_text_ctx = 0;
    p.offset_ms = 0;
    p.duration_ms = 0;
    p.translate = false;
    p.no_context = true;
    p.no_timestamps = false;
    p.single_segment = false;
    p.print_special = false;
    p.print_progress = false;
    p.print_realtime = false;
    p.print_timestamps = false;
    p.token_timestamps = false;
    p.thold_pt = 0.01f;
    p.thold_ptsum = 0.01f;
    p.max_len = 0;
    p.split_on_word = false;
    p.max_tokens = 0;
    p.debug_mode = false;
    p.audio_ctx = 0;
    p.tdrz_enable = false;
    p.suppress_regex = NULL;
    p.initial_prompt = NULL;
    p.carry_initial_prompt = false;
    p.prompt_tokens = NULL;
    p.prompt_n_tokens = 0;
    p.language = "en";
    p.detect_language = false;
    p.suppress_blank = true;
    p.suppress_nst = false;
    p.temperature = 0.0f;
    p.max_initial_ts = 1.0f;
    p.length_penalty = -1.0f;
    p.temperature_inc = 0.2f;
    p.entropy_thold = 2.4f;
    p.logprob_thold = -1.0f;
    p.no_speech_thold = 0.6f;
    p.greedy.best_of = 5;
    p.beam_search.beam_size = -1;
    p.beam_search.patience = -1.0f;
    p.new_segment_callback = NULL;
    p.new_segment_callback_user_data = NULL;
    p.progress_callback = NULL;
    p.progress_callback_user_data = NULL;
    p.encoder_begin_callback = NULL;
    p.encoder_begin_callback_user_data = NULL;
    p.abort_callback = NULL;
    p.abort_callback_user_data = NULL;
    p.logits_filter_callback = NULL;
    p.logits_filter_callback_user_data = NULL;
    p.grammar_rules = NULL;
    p.n_grammar_rules = 0;
    p.i_start_rule = 0;
    p.grammar_penalty = 100.0f;
    p.vad = false;
    p.vad_model_path = NULL;
    p.vad_params = whisper_vad_default_params();
    return p;
}

int lr_whisper_configuration_is_expected(void) {
    struct whisper_context_params c = context_params();
    struct whisper_full_params p = full_params();
    return c.use_gpu == false && c.flash_attn == false &&
        c.dtw_token_timestamps == false &&
        p.strategy == WHISPER_SAMPLING_GREEDY && p.n_threads == 4 &&
        p.translate == false && p.no_context == true &&
        p.no_timestamps == false && p.single_segment == false &&
        p.print_special == false && p.print_progress == false &&
        p.print_realtime == false && p.print_timestamps == false &&
        p.token_timestamps == false && p.initial_prompt == NULL &&
        p.detect_language == false && strcmp(p.language, "en") == 0 &&
        p.tdrz_enable == false && p.vad == false;
}

int lr_whisper_run(LRWhisperContext context, const float * samples, int sample_count) {
    if (context == NULL || samples == NULL || sample_count < 0 ||
        !lr_whisper_configuration_is_expected()) return -1;
    struct whisper_full_params p = full_params();
    return whisper_full((struct whisper_context *) context, p, samples, sample_count);
}

int lr_whisper_segment_count(LRWhisperContext context) {
    return whisper_full_n_segments((struct whisper_context *) context);
}
int64_t lr_whisper_segment_start(LRWhisperContext context, int index) {
    return whisper_full_get_segment_t0((struct whisper_context *) context, index);
}
int64_t lr_whisper_segment_end(LRWhisperContext context, int index) {
    return whisper_full_get_segment_t1((struct whisper_context *) context, index);
}
const char * lr_whisper_segment_text(LRWhisperContext context, int index) {
    return whisper_full_get_segment_text((struct whisper_context *) context, index);
}
const char * lr_whisper_version(void) { return whisper_version(); }
