#ifndef LECTURE_RECORDER_WHISPER_BRIDGE_H
#define LECTURE_RECORDER_WHISPER_BRIDGE_H

#include <stdint.h>

typedef void * LRWhisperContext;
typedef void * LRWhisperVerifiedModel;

enum LRWhisperModelStatus {
    LR_WHISPER_MODEL_OK = 0,
    LR_WHISPER_MODEL_OPEN_FAILED = 1,
    LR_WHISPER_MODEL_NOT_REGULAR = 2,
    LR_WHISPER_MODEL_SIZE_MISMATCH = 3,
    LR_WHISPER_MODEL_DIGEST_MISMATCH = 4,
    LR_WHISPER_MODEL_REWIND_FAILED = 5,
    LR_WHISPER_MODEL_INITIALIZATION_FAILED = 6,
    LR_WHISPER_MODEL_MUTATED = 7,
    LR_WHISPER_MODEL_CLOSE_FAILED = 8,
};

struct LRWhisperModelReport {
    enum LRWhisperModelStatus status;
    uint64_t bytes_hashed;
    uint64_t bytes_loaded;
    uint64_t loader_read_calls;
    uint32_t loader_close_calls;
    uint32_t descriptor_close_calls;
    uint8_t first_loaded_bytes[8];
    uint32_t first_loaded_byte_count;
};

LRWhisperVerifiedModel lr_whisper_model_open_verified(
    const char * model_path,
    struct LRWhisperModelReport * report
);
LRWhisperContext lr_whisper_model_initialize(
    LRWhisperVerifiedModel model,
    struct LRWhisperModelReport * report
);
void lr_whisper_model_discard(
    LRWhisperVerifiedModel model,
    struct LRWhisperModelReport * report
);

#if defined(LR_WHISPER_TESTING)
LRWhisperVerifiedModel lr_whisper_model_open_verified_for_testing(
    const char * model_path,
    uint64_t expected_size,
    const char * expected_sha256,
    struct LRWhisperModelReport * report
);
#endif

void lr_whisper_destroy(LRWhisperContext context);
int lr_whisper_run(LRWhisperContext context, const float * samples, int sample_count);
int lr_whisper_configuration_is_expected(void);
int lr_whisper_segment_count(LRWhisperContext context);
int64_t lr_whisper_segment_start(LRWhisperContext context, int index);
int64_t lr_whisper_segment_end(LRWhisperContext context, int index);
const char * lr_whisper_segment_text(LRWhisperContext context, int index);
const char * lr_whisper_version(void);

#endif
