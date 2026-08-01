/**
 * Companies House fixed-width snapshot parser — C ABI
 *
 * No filesystem I/O. Suitable for native FFI and freestanding WASM.
 *
 * Modes:
 * - One-shot: ch_parse_snapshot (full input → full companies + persons CSV)
 * - Streaming: ch_stream_* (chunked input → batched CSV pull; preferred for large files)
 *
 * Link against libch_fixedwidth (static/shared) or import the freestanding WASM module.
 */

#ifndef CH_FIXEDWIDTH_H
#define CH_FIXEDWIDTH_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/** Heap buffer owned by the library until freed with ch_buffer_free. */
typedef struct ChBuffer {
    uint8_t *data;
    size_t len;
} ChBuffer;

typedef struct ChParseResult {
    ChBuffer companies_csv;
    ChBuffer persons_csv;
    int32_t companies;
    int32_t persons;
    int32_t trailer_count;
} ChParseResult;

/** Success */
#define CH_OK 0
/** NULL pointer or empty input */
#define CH_ERR_INVALID_ARG 1
/** Header is unknown / too short (not a recognised product magic) */
#define CH_ERR_UNSUPPORTED_HEADER 2
/** No trailer record */
#define CH_ERR_MISSING_TRAILER 3
/** Trailer count does not match rows written */
#define CH_ERR_TRAILER_MISMATCH 4
/** Allocation failure */
#define CH_ERR_OUT_OF_MEMORY 5
/** Unspecified failure */
#define CH_ERR_INTERNAL 6
/** Stream used after finish, or non-whitespace data after trailer */
#define CH_ERR_STREAM_STATE 7
/** Known product header (e.g. DDDDUPDT / DISQUALS) but body parser not implemented yet */
#define CH_ERR_NOT_IMPLEMENTED 8

/**
 * Parse a full snapshot document in memory into two CSV documents (with headers).
 *
 * On CH_OK, free the result with ch_parse_result_free().
 * For multi-hundred-MB / GB files, use the streaming API instead.
 */
int ch_parse_snapshot(const uint8_t *input, size_t input_len, ChParseResult *out);

/** Free one buffer previously filled by ch_parse_snapshot. */
void ch_buffer_free(ChBuffer *buf);

/** Free both CSV buffers in a parse result and zero counts. */
void ch_parse_result_free(ChParseResult *result);

/** Allocate size bytes (e.g. host copies input for WASM). Free with ch_free. */
uint8_t *ch_alloc(size_t size);

/** Free memory from ch_alloc. */
void ch_free(uint8_t *ptr, size_t size);

/* --- Streaming API (chunked input, batched CSV output) --------------------- */

/**
 * Batching thresholds. Pass NULL to ch_stream_create for defaults.
 * A zero field means "use default" (1000 rows / 262144 bytes).
 */
typedef struct ChStreamConfig {
    size_t batch_rows;
    size_t batch_bytes;
} ChStreamConfig;

/** One CSV batch (companies or persons). Free with ch_csv_batch_free. */
typedef struct ChCsvBatch {
    uint8_t *data;
    size_t len;
    int32_t row_count;
    /** 0 = companies, 1 = persons */
    int32_t kind;
} ChCsvBatch;

/** Opaque stream parser. */
typedef struct ChStream ChStream;

#define CH_BATCH_COMPANIES 0
#define CH_BATCH_PERSONS 1

/**
 * Create a stream. Free with ch_stream_destroy.
 * Returns NULL on allocation failure.
 */
ChStream *ch_stream_create(const ChStreamConfig *config);

/** Destroy stream and any undrained batches. */
void ch_stream_destroy(ChStream *s);

/**
 * Feed the next input chunk (any size; need not end on a newline).
 * After CH_OK, drain with ch_stream_next_batch until it returns 0.
 */
int ch_stream_feed(ChStream *s, const uint8_t *data, size_t len);

/**
 * End of input: flush open batches and validate trailer.
 * Drain batches after CH_OK.
 */
int ch_stream_finish(ChStream *s);

/**
 * Pop one completed CSV batch into out.
 * Returns 1 if a batch was written, 0 if none pending, or an error code (< 0 not used;
 * errors are positive CH_ERR_* values; success with no batch is 0).
 * On 1, free out with ch_csv_batch_free.
 */
int ch_stream_next_batch(ChStream *s, ChCsvBatch *out);

/** Free a batch from ch_stream_next_batch. */
void ch_csv_batch_free(ChCsvBatch *batch);

/** Row counts. trailer_count is 0 until a trailer line has been seen. */
void ch_stream_stats(const ChStream *s, int32_t *companies, int32_t *persons, int32_t *trailer_count);

#ifdef __cplusplus
}
#endif

#endif /* CH_FIXEDWIDTH_H */
