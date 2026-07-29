/* ---------------------------------------------------------------------------
 * loom.h — the C ABI of the Loom engine
 * ---------------------------------------------------------------------------
 *
 * This header is the constitutional border of LuciaOS: everything below it
 * is the Zig engine; everything above it (shells, platform code, legacy
 * C++, specialized runtimes) speaks only these functions.  The ABI covers
 * what a client needs to build, wire, observe, and evaluate a Fabric —
 * store lifecycle, transactions, volatile observations, the change feed,
 * the fiber index, and demand through the spool with client-supplied
 * evaluators.  Effects, capabilities, arrangements, and blobs stay behind
 * the border for now and surface here when a client needs them.
 *
 * Conventions
 *   - Functions return loom_status; LOOM_OK is zero.
 *   - Texel identities are 32 raw bytes (LOOM_ID_SIZE).
 *   - Names (ports, evaluators) are NUL-terminated UTF-8.
 *   - loom_buffer values returned by the engine are owned by the caller
 *     and released with loom_buffer_free.  Buffers passed in are
 *     borrowed; the engine copies what it keeps.
 *   - Handles are single-threaded in this version.
 */

#ifndef LUCIA_LOOM_H
#define LUCIA_LOOM_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

enum { LOOM_ID_SIZE = 32, LOOM_ID_TEXT_SIZE = 64 };

typedef enum {
    LOOM_OK = 0,
    LOOM_ERR_ARGUMENT,
    LOOM_ERR_NOT_FOUND,
    LOOM_ERR_TYPE,
    LOOM_ERR_STALE,
    LOOM_ERR_IMAGE,
    LOOM_ERR_PUBLISH,
    LOOM_ERR_RING_GAP,
    LOOM_ERR_MEMORY
} loom_status;

/* Tags match the persisted value encoding; never reorder. */
typedef enum {
    LOOM_VALUE_NONE = 0,
    LOOM_VALUE_BOOL = 1,
    LOOM_VALUE_INT = 2,
    LOOM_VALUE_REAL = 3,
    LOOM_VALUE_TEXT = 4,
    LOOM_VALUE_BYTES = 5,
    LOOM_VALUE_TEXEL = 6,
    LOOM_VALUE_BLOB = 7
} loom_value_tag;

typedef struct {
    uint8_t *data;
    size_t size;
} loom_buffer;

void loom_buffer_free(loom_buffer buffer);

/* One typed value.  Only the field selected by tag is meaningful; text
 * and bytes travel in data. */
typedef struct {
    uint8_t tag;
    bool boolean;
    int64_t integer;
    double real;
    loom_buffer data;
    uint8_t texel[LOOM_ID_SIZE];
    uint8_t blob_id[LOOM_ID_SIZE];
    uint64_t blob_size;
} loom_value;

void loom_value_free(loom_value *value);

typedef enum {
    LOOM_OUTCOME_AVAILABLE = 0,
    LOOM_OUTCOME_UNAVAILABLE = 1,
    LOOM_OUTCOME_ERROR = 2
} loom_outcome_status;

/* Explicit result of demanding a value. */
typedef struct {
    uint8_t status;
    loom_value value;        /* available only */
    loom_buffer error_message; /* error only */
} loom_outcome;

void loom_outcome_free(loom_outcome *outcome);

/* Identity ---------------------------------------------------------------- */

void loom_id_generate(uint8_t id[LOOM_ID_SIZE]);
loom_status loom_id_parse(const char *text, uint8_t id[LOOM_ID_SIZE]);
/* Writes LOOM_ID_TEXT_SIZE hex characters plus a terminating NUL. */
void loom_id_format(const uint8_t id[LOOM_ID_SIZE], char text[LOOM_ID_TEXT_SIZE + 1]);

/* Store ------------------------------------------------------------------- */

typedef struct loom_store loom_store;

loom_status loom_store_create(const char *path, uint64_t pages, loom_store **store);
loom_status loom_store_open(const char *path, loom_store **store);
void loom_store_close(loom_store *store);

uint64_t loom_store_generation(const loom_store *store);
size_t loom_store_count(const loom_store *store);
loom_status loom_store_id_at(const loom_store *store, size_t index,
                             uint8_t id[LOOM_ID_SIZE]);
bool loom_store_has(const loom_store *store, const uint8_t id[LOOM_ID_SIZE]);

/* Texel inspection.  Info structs own their buffers; free after use. */

typedef struct {
    loom_buffer name;
    uint8_t type;
    bool bound;
    uint8_t source[LOOM_ID_SIZE]; /* bound only */
    loom_buffer source_output;    /* bound only */
} loom_input_info;

typedef struct {
    loom_buffer name;
    uint8_t type;
    bool has_source;
    loom_value source; /* has_source only */
    uint64_t revision;
} loom_output_info;

void loom_input_info_free(loom_input_info *info);
void loom_output_info_free(loom_output_info *info);

loom_status loom_texel_revision(const loom_store *store,
                                const uint8_t id[LOOM_ID_SIZE], uint64_t *revision);
/* Empty buffer when the texel has no evaluator. */
loom_status loom_texel_evaluator(const loom_store *store,
                                 const uint8_t id[LOOM_ID_SIZE], loom_buffer *name);
loom_status loom_texel_input_count(const loom_store *store,
                                   const uint8_t id[LOOM_ID_SIZE], size_t *count);
loom_status loom_texel_input_at(const loom_store *store, const uint8_t id[LOOM_ID_SIZE],
                                size_t index, loom_input_info *info);
loom_status loom_texel_output_count(const loom_store *store,
                                    const uint8_t id[LOOM_ID_SIZE], size_t *count);
loom_status loom_texel_output_at(const loom_store *store, const uint8_t id[LOOM_ID_SIZE],
                                 size_t index, loom_output_info *info);

/* Transactions ------------------------------------------------------------ */
/* A private working snapshot; nothing is visible until commit publishes a
 * new durable generation.  Operations address texels by identity and do
 * the clone-modify-place dance internally.  Release always; it is safe
 * after commit. */

typedef struct loom_txn loom_txn;

loom_status loom_txn_begin(loom_store *store, loom_txn **txn);
loom_status loom_txn_commit(loom_txn *txn);
void loom_txn_release(loom_txn *txn);

/* Creates an empty texel with a freshly generated identity. */
loom_status loom_txn_create_texel(loom_txn *txn, uint8_t id[LOOM_ID_SIZE]);
loom_status loom_txn_remove_texel(loom_txn *txn, const uint8_t id[LOOM_ID_SIZE]);

loom_status loom_txn_put_input(loom_txn *txn, const uint8_t id[LOOM_ID_SIZE],
                               const char *name, uint8_t type);
loom_status loom_txn_put_output(loom_txn *txn, const uint8_t id[LOOM_ID_SIZE],
                                const char *name, uint8_t type);
loom_status loom_txn_remove_input(loom_txn *txn, const uint8_t id[LOOM_ID_SIZE],
                                  const char *name);
loom_status loom_txn_remove_output(loom_txn *txn, const uint8_t id[LOOM_ID_SIZE],
                                   const char *name);

loom_status loom_txn_set_evaluator(loom_txn *txn, const uint8_t id[LOOM_ID_SIZE],
                                   const char *name);
/* The value is borrowed; the engine stores its own copy. */
loom_status loom_txn_set_source(loom_txn *txn, const uint8_t id[LOOM_ID_SIZE],
                                const char *output, const loom_value *value);

loom_status loom_txn_connect(loom_txn *txn, const uint8_t target[LOOM_ID_SIZE],
                             const char *input, const uint8_t source[LOOM_ID_SIZE],
                             const char *output);
loom_status loom_txn_disconnect(loom_txn *txn, const uint8_t target[LOOM_ID_SIZE],
                                const char *input);

/* Observation and the change feed ----------------------------------------- */

/* Volatile push: updates the observed output in memory only, advancing
 * the logical generation; reopen reverts to the last durable snapshot. */
loom_status loom_store_observe(loom_store *store, const uint8_t id[LOOM_ID_SIZE],
                               const char *output, const loom_value *value);

typedef struct {
    uint8_t *ids; /* count * LOOM_ID_SIZE bytes */
    size_t count;
} loom_id_list;

void loom_id_list_free(loom_id_list list);

/* Union of texels changed in (baseline, current].  LOOM_ERR_RING_GAP
 * means the ring no longer covers the span: rebuild instead. */
loom_status loom_store_changes_since(const loom_store *store, uint64_t baseline,
                                     loom_id_list *changed);

/* Fiber index ------------------------------------------------------------- */
/* Disposable reverse index; expands a change delta into the conservative
 * dirty closure.  Push invalidates; pull evaluates. */

typedef struct loom_index loom_index;

loom_status loom_index_new(loom_index **index);
void loom_index_free(loom_index *index);
loom_status loom_index_build(loom_index *index, const loom_store *store);
loom_status loom_index_apply(loom_index *index, const loom_store *store,
                             const loom_id_list *changed);
loom_status loom_index_downstream(const loom_index *index, const loom_id_list *changed,
                                  loom_id_list *dirty);

/* Evaluation -------------------------------------------------------------- */

/* One evaluator input: the port name and its demanded outcome.  Both are
 * borrowed for the duration of the callback. */
typedef struct {
    const char *name;
    const loom_outcome *outcome;
} loom_eval_input;

/* The evaluator emits one outcome per declared output through this sink;
 * emitted values are copied immediately, so stack storage is fine. */
typedef void (*loom_emit_fn)(void *sink, const char *output, const loom_outcome *outcome);

/* Pure computation: read inputs, emit every declared output.  Must not
 * touch the store; it receives values, never the world. */
typedef void (*loom_evaluator_fn)(void *context, const loom_eval_input *inputs,
                                  size_t input_count, loom_emit_fn emit, void *sink);

typedef struct loom_registry loom_registry;

loom_status loom_registry_new(loom_registry **registry);
void loom_registry_free(loom_registry *registry);
loom_status loom_registry_put(loom_registry *registry, const char *name,
                              loom_evaluator_fn evaluator, void *context);

/* A disposable demand cache over one store and registry, both borrowed
 * and required to outlive the spool. */
typedef struct loom_spool loom_spool;

loom_status loom_spool_new(loom_store *store, const loom_registry *registry,
                           loom_spool **spool);
void loom_spool_free(loom_spool *spool);

/* Demand one output; the outcome is owned by the caller. */
loom_status loom_spool_demand(loom_spool *spool, const uint8_t id[LOOM_ID_SIZE],
                              const char *output, loom_outcome *outcome);
/* Stamp records clean across a reconcile step; dirty is the conservative
 * transitive closure of everything changed in between. */
void loom_spool_advance(loom_spool *spool, uint64_t from_generation,
                        uint64_t to_generation, const loom_id_list *dirty);
void loom_spool_clear(loom_spool *spool);

#ifdef __cplusplus
} /* extern "C" */
#endif

#endif /* LUCIA_LOOM_H */
