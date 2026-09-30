#ifndef REPLICATOR_CODEC_H
#define REPLICATOR_CODEC_H
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
/* ABI 4. Handles are opaque, serial-use and released exactly once. Invalid
 * non-null/dangling pointers are a caller contract violation, as in any C API.
 * Input buffers are borrowed only for feed(). Results own all returned storage,
 * independent of input/context lifetimes, until result_free(). Views are borrowed
 * from that result. Never free Rust buffers with a Swift/C allocator.
 * Status: 0 OK, 1 argument, 2 malformed, 3 checksum, 4 unsupported,
 *         5 resource limit, 6 poisoned context, 7 missing schema, 8 internal panic.
 * Every failed feed poisons the context. Reset discards ALL metadata; replay from
 * the file's FDE is required. No data from a failed event may be published.
 */
typedef struct rc_decoder rc_decoder;
typedef struct rc_result rc_result;
typedef struct { const uint8_t *data; uint64_t length; } rc_bytes;
typedef struct {
    uint64_t offset, number, table_id;
    uint32_t event_type, timestamp, server_id, next_position, flags, row_count, column_count;
    /* payload_flags: GTID flags for types 33/34, row flags for 23-25/30-32.
     * query_error_code/query_status: source QUERY_EVENT error and status bytes.
     * Header flags and row/GTID flags are distinct namespaces. */
    uint32_t event_size, payload_flags, query_error_code;
    rc_bytes query_status;
    rc_bytes name, database, table, detail, raw, error, fingerprint;
} rc_event;
/* Value kinds: 0 absent, 1 SQL NULL, 2 signed integer, 3 unsigned integer,
 * 4 UTF-8 text, 5 binary. Text/binary are pointer+length, including embedded NUL.
 * Column interpretations supplied on TABLE_MAP only: 2/3/4/5, in column order.
 * History is mandatory for rows, even if optional wire metadata happens to exist.
 */
typedef struct { uint32_t kind; int64_t signed_value; uint64_t unsigned_value; rc_bytes bytes; } rc_value;
/* TABLE_MAP metadata. kind=0 means missing/unsupported wire interpretation;
 * collation=0 means unavailable/not applicable; name may be empty in MINIMAL.
 * maximum_bytes is populated for VARCHAR/VARBINARY (wire type 15). */
typedef struct { uint32_t kind, column_type, maximum_bytes, nullable, collation, primary_key; rc_bytes name; } rc_column;
int32_t rc_result_column(const rc_result *result, uint32_t column, rc_column *out);
/* Additive ABI 4 query-context API. present uses MySQL Q_* status tag bits.
 * No pointers in output. Unknown, truncated or duplicate status fields fail. */
typedef struct {
    uint64_t sql_mode;
    uint32_t present, flags2, charset_client, collation_connection, collation_server,
        collation_database, default_collation_utf8mb4;
} rc_query_context;
int32_t rc_query_context_decode(const uint8_t *bytes, uint64_t length, rc_query_context *out);
uint32_t replicator_codec_abi_version(void);
uint64_t replicator_codec_capabilities(void); /* bit 0: bounded offline decoder */
int32_t rc_decoder_create(uint32_t max_event_bytes, rc_decoder **out);
int32_t rc_decoder_reset(rc_decoder *decoder);
void rc_decoder_free(rc_decoder *decoder);
int32_t rc_decoder_feed(rc_decoder *decoder, const uint8_t *bytes, uint64_t length,
    uint64_t offset, const uint32_t *column_kinds, uint32_t column_count, rc_result **out);
int32_t rc_result_event(const rc_result *result, rc_event *out);
/* image: 0 before, 1 after. A missing image has only absent values.
 * Query row_count / column_count first. Bounds errors return status 1. */
int32_t rc_result_value(const rc_result *result, uint32_t row, uint32_t image, uint32_t column, rc_value *out);
void rc_result_free(rc_result *result);
#ifdef __cplusplus
}
#endif
#endif
