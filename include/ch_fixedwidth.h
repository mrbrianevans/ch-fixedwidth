/**
 * ch_fixedwidth — Companies House fixed-width multi-product parser (C ABI)
 *
 * No filesystem I/O. Suitable for native FFI and freestanding WASM.
 *
 * Modes:
 * - One-shot: ch_parse (full input → named CSV documents per product)
 * - Streaming: ch_stream_* (chunked input → batched CSV by CH_OUTPUT_*)
 *
 * Products are selected from the first 8-byte header magic. Output kinds are
 * never overloaded: liquidation forms use CH_OUTPUT_FORMS, not companies.
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

/** Product id after header magic is known. Matches Zig parse.FileType. */
#define CH_FILE_UNKNOWN (-1)
#define CH_FILE_OFFICERS_SNAPSHOT 0
#define CH_FILE_OFFICERS_UPDATE 1
#define CH_FILE_DISQUALIFICATIONS 2
#define CH_FILE_LIQUIDATION 3

/** CSV output channel. Matches Zig parse.OutputKind. */
#define CH_OUTPUT_COMPANIES 0
#define CH_OUTPUT_PERSONS 1
#define CH_OUTPUT_DISQUALIFICATIONS 2
#define CH_OUTPUT_EXEMPTIONS 3
#define CH_OUTPUT_VARIATIONS 4
#define CH_OUTPUT_FORMS 5
#define CH_OUTPUT_PRACTITIONERS 6
#define CH_OUTPUT_FREE_TEXT 7

/** Max product numbers per format entry (officers snapshot has two: 195, 216). */
#define CH_MAX_PRODUCT_CODES 4

/**
 * One supported bulk file format (static strings; do not free).
 *
 * | file_type | product_codes | header | description |
 * |-----------|---------------|--------|-------------|
 * | 0 snapshot | 195, 216 | DDDDSNAP | officers snapshot |
 * | 1 update | 198 | DDDDUPDT | officers update |
 * | 2 disqual | 192 | DISQUALS | disqualifications |
 * | 3 liquidation | 197 | LIQNFORM | liquidations |
 */
typedef struct ChSupportedFormat {
    int32_t file_type;
    uint32_t product_code_count;
    uint16_t product_codes[CH_MAX_PRODUCT_CODES];
    const char *header_identifier;
    const char *description;
} ChSupportedFormat;

/**
 * One-shot parse result. Unused kinds have empty buffers and zero counts.
 *
 * Layout (wasm32 and native): ten int32 counts, then eight ChBuffer fields.
 *
 * | Product | Filled outputs |
 * |---------|----------------|
 * | Officers 195/216/198 | companies, persons |
 * | Disqualifications 192 | persons, disqualifications, exemptions, variations |
 * | Liquidation 197 | forms, practitioners, free_text |
 */
typedef struct ChParseResult {
    int32_t file_type;
    int32_t trailer_count;
    int32_t companies;
    int32_t persons;
    int32_t disqualifications;
    int32_t exemptions;
    int32_t variations;
    int32_t forms;
    int32_t practitioners;
    int32_t free_text;
    ChBuffer companies_csv;
    ChBuffer persons_csv;
    ChBuffer disqualifications_csv;
    ChBuffer exemptions_csv;
    ChBuffer variations_csv;
    ChBuffer forms_csv;
    ChBuffer practitioners_csv;
    ChBuffer free_text_csv;
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
/** Known product header but body parser not implemented yet */
#define CH_ERR_NOT_IMPLEMENTED 8
/** Formatted CSV row exceeds the internal row buffer */
#define CH_ERR_ROW_TOO_LARGE 9
/** Prod 197 form group exceeded max practitioners or free-text lines */
#define CH_ERR_RECORD_LIMIT 10

/**
 * Return a pointer to a static array of supported file formats.
 * When out_count is non-NULL, it is set to the number of entries.
 * The pointer is valid for the process lifetime; do not free.
 */
const ChSupportedFormat *ch_supported_formats(size_t *out_count);

/**
 * Parse a full fixed-width document in memory into named CSV documents.
 * On CH_OK, free the result with ch_parse_result_free().
 * For multi-hundred-MB / GB files, use the streaming API instead.
 */
int ch_parse(const uint8_t *input, size_t input_len, ChParseResult *out);

/** Free one buffer previously filled by ch_parse. */
void ch_buffer_free(ChBuffer *buf);

/** Free all CSV buffers in a parse result and zero counts. */
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

/** One CSV batch for a single CH_OUTPUT_* kind. Free with ch_csv_batch_free. */
typedef struct ChCsvBatch {
    uint8_t *data;
    size_t len;
    int32_t row_count;
    /** CH_OUTPUT_* */
    int32_t kind;
} ChCsvBatch;

/** Cumulative stats for an active stream. */
typedef struct ChStreamStats {
    int32_t file_type;
    int32_t trailer_count;
    int32_t companies;
    int32_t persons;
    int32_t disqualifications;
    int32_t exemptions;
    int32_t variations;
    int32_t forms;
    int32_t practitioners;
    int32_t free_text;
} ChStreamStats;

/** Opaque stream parser. */
typedef struct ChStream ChStream;

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
 * Returns 1 if a batch was written, 0 if none pending, or a positive CH_ERR_*.
 * On 1, free out with ch_csv_batch_free.
 */
int ch_stream_next_batch(ChStream *s, ChCsvBatch *out);

/** Free a batch from ch_stream_next_batch. */
void ch_csv_batch_free(ChCsvBatch *batch);

/** Fill out with cumulative row counts and product id. */
void ch_stream_stats(const ChStream *s, ChStreamStats *out);

#ifdef __cplusplus
}
#endif

#endif /* CH_FIXEDWIDTH_H */
