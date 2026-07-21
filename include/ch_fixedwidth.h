/**
 * Companies House fixed-width snapshot parser — C ABI
 *
 * In-memory parse only (no filesystem I/O). Suitable for native FFI and WASM.
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
/** Header is not DDDDSNAP / too short */
#define CH_ERR_UNSUPPORTED_HEADER 2
/** No trailer record */
#define CH_ERR_MISSING_TRAILER 3
/** Trailer count does not match rows written */
#define CH_ERR_TRAILER_MISMATCH 4
/** Allocation failure */
#define CH_ERR_OUT_OF_MEMORY 5
/** Unspecified failure */
#define CH_ERR_INTERNAL 6

/**
 * Parse a full snapshot document in memory into two CSV documents (with headers).
 *
 * On CH_OK, free the result with ch_parse_result_free().
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

#ifdef __cplusplus
}
#endif

#endif /* CH_FIXEDWIDTH_H */
