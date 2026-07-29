/* Smoke test: drive the Loom engine from C across abi/loom.h.
 *
 * Builds a Fabric, wires a computed texel to a C evaluator, demands it,
 * observes a change, reconciles through the index, and reopens the image
 * — the same lifecycle every client above the border will use.
 */

#include "loom.h"

#include <stdio.h>
#include <string.h>

static int failures = 0;

#define CHECK(condition)                                                     \
    do {                                                                     \
        if (!(condition)) {                                                  \
            fprintf(stderr, "fail: %s (%s:%d)\n", #condition, __FILE__,      \
                    __LINE__);                                               \
            ++failures;                                                      \
        }                                                                    \
    } while (0)

static loom_value text_value(const char *text) {
    loom_value value;
    memset(&value, 0, sizeof(value));
    value.tag = LOOM_VALUE_TEXT;
    value.data.data = (uint8_t *)text;
    value.data.size = strlen(text);
    return value;
}

/* upper: raise the "text" input; emit "value". */
static void upper_evaluator(void *context, const loom_eval_input *inputs,
                            size_t input_count, loom_emit_fn emit, void *sink) {
    size_t *calls = (size_t *)context;
    ++*calls;

    loom_outcome result;
    memset(&result, 0, sizeof(result));
    result.status = LOOM_OUTCOME_UNAVAILABLE;

    uint8_t raised[256];
    for (size_t i = 0; i < input_count; ++i) {
        if (strcmp(inputs[i].name, "text") != 0) {
            continue;
        }
        const loom_outcome *in = inputs[i].outcome;
        if (in->status != LOOM_OUTCOME_AVAILABLE ||
            in->value.tag != LOOM_VALUE_TEXT || in->value.data.size > 256) {
            break;
        }
        for (size_t at = 0; at < in->value.data.size; ++at) {
            uint8_t c = in->value.data.data[at];
            raised[at] = (uint8_t)(c >= 'a' && c <= 'z' ? c - 32 : c);
        }
        result.status = LOOM_OUTCOME_AVAILABLE;
        result.value.tag = LOOM_VALUE_TEXT;
        result.value.data.data = raised;
        result.value.data.size = in->value.data.size;
    }
    emit(sink, "value", &result);
}

int main(void) {
    const char *image = "abi-smoke.img";
    loom_store *store = NULL;
    CHECK(loom_store_create(image, 32, &store) == LOOM_OK);
    CHECK(loom_store_generation(store) == 1);

    /* Build: a source texel and an upper texel wired to it. */
    uint8_t source_id[LOOM_ID_SIZE];
    uint8_t shout_id[LOOM_ID_SIZE];
    {
        loom_txn *txn = NULL;
        CHECK(loom_txn_begin(store, &txn) == LOOM_OK);
        CHECK(loom_txn_create_texel(txn, source_id) == LOOM_OK);
        CHECK(loom_txn_put_output(txn, source_id, "value", LOOM_VALUE_TEXT) == LOOM_OK);
        loom_value hello = text_value("hello");
        CHECK(loom_txn_set_source(txn, source_id, "value", &hello) == LOOM_OK);

        CHECK(loom_txn_create_texel(txn, shout_id) == LOOM_OK);
        CHECK(loom_txn_set_evaluator(txn, shout_id, "upper") == LOOM_OK);
        CHECK(loom_txn_put_input(txn, shout_id, "text", LOOM_VALUE_TEXT) == LOOM_OK);
        CHECK(loom_txn_put_output(txn, shout_id, "value", LOOM_VALUE_TEXT) == LOOM_OK);
        CHECK(loom_txn_connect(txn, shout_id, "text", source_id, "value") == LOOM_OK);
        CHECK(loom_txn_commit(txn) == LOOM_OK);
        loom_txn_release(txn);
    }
    CHECK(loom_store_count(store) == 2);

    /* A type mismatch is refused at the border. */
    {
        loom_txn *txn = NULL;
        CHECK(loom_txn_begin(store, &txn) == LOOM_OK);
        loom_value wrong;
        memset(&wrong, 0, sizeof(wrong));
        wrong.tag = LOOM_VALUE_BOOL;
        wrong.boolean = true;
        CHECK(loom_txn_set_source(txn, source_id, "value", &wrong) == LOOM_ERR_TYPE);
        loom_txn_release(txn);
    }

    /* Demand through a C evaluator. */
    size_t calls = 0;
    loom_registry *registry = NULL;
    loom_spool *spool = NULL;
    CHECK(loom_registry_new(&registry) == LOOM_OK);
    CHECK(loom_registry_put(registry, "upper", upper_evaluator, &calls) == LOOM_OK);
    CHECK(loom_spool_new(store, registry, &spool) == LOOM_OK);

    uint64_t seen = loom_store_generation(store);
    loom_outcome outcome;
    CHECK(loom_spool_demand(spool, shout_id, "value", &outcome) == LOOM_OK);
    CHECK(outcome.status == LOOM_OUTCOME_AVAILABLE);
    CHECK(outcome.value.data.size == 5);
    CHECK(memcmp(outcome.value.data.data, "HELLO", 5) == 0);
    CHECK(calls == 1);
    loom_outcome_free(&outcome);

    /* Cached demand runs no evaluator. */
    CHECK(loom_spool_demand(spool, shout_id, "value", &outcome) == LOOM_OK);
    CHECK(calls == 1);
    loom_outcome_free(&outcome);

    /* Observe (volatile push), reconcile, re-demand: one recompute. */
    loom_index *index = NULL;
    CHECK(loom_index_new(&index) == LOOM_OK);
    CHECK(loom_index_build(index, store) == LOOM_OK);

    loom_value moved = text_value("moved");
    CHECK(loom_store_observe(store, source_id, "value", &moved) == LOOM_OK);

    loom_id_list changed;
    CHECK(loom_store_changes_since(store, seen, &changed) == LOOM_OK);
    CHECK(changed.count == 1);
    loom_id_list dirty;
    CHECK(loom_index_apply(index, store, &changed) == LOOM_OK);
    CHECK(loom_index_downstream(index, &changed, &dirty) == LOOM_OK);
    CHECK(dirty.count == 2); /* source and shout */
    loom_spool_advance(spool, seen, loom_store_generation(store), &dirty);
    seen = loom_store_generation(store);
    loom_id_list_free(changed);
    loom_id_list_free(dirty);

    CHECK(loom_spool_demand(spool, shout_id, "value", &outcome) == LOOM_OK);
    CHECK(outcome.status == LOOM_OUTCOME_AVAILABLE);
    CHECK(memcmp(outcome.value.data.data, "MOVED", 5) == 0);
    CHECK(calls == 2);
    loom_outcome_free(&outcome);

    /* Identity text round-trips. */
    char text[LOOM_ID_TEXT_SIZE + 1];
    uint8_t parsed[LOOM_ID_SIZE];
    loom_id_format(shout_id, text);
    CHECK(strlen(text) == LOOM_ID_TEXT_SIZE);
    CHECK(loom_id_parse(text, parsed) == LOOM_OK);
    CHECK(memcmp(parsed, shout_id, LOOM_ID_SIZE) == 0);

    /* Inspection walks ports and bindings. */
    {
        size_t inputs = 0;
        loom_input_info info;
        CHECK(loom_texel_input_count(store, shout_id, &inputs) == LOOM_OK);
        CHECK(inputs == 1);
        CHECK(loom_texel_input_at(store, shout_id, 0, &info) == LOOM_OK);
        CHECK(info.name.size == 4 && memcmp(info.name.data, "text", 4) == 0);
        CHECK(info.bound);
        CHECK(memcmp(info.source, source_id, LOOM_ID_SIZE) == 0);
        loom_input_info_free(&info);

        loom_buffer evaluator;
        CHECK(loom_texel_evaluator(store, shout_id, &evaluator) == LOOM_OK);
        CHECK(evaluator.size == 5 && memcmp(evaluator.data, "upper", 5) == 0);
        loom_buffer_free(evaluator);
    }

    loom_spool_free(spool);
    loom_registry_free(registry);
    loom_index_free(index);
    loom_store_close(store);

    /* Reopen: durable state survives, the observation does not. */
    CHECK(loom_store_open(image, &store) == LOOM_OK);
    CHECK(loom_store_count(store) == 2);
    {
        loom_output_info info;
        CHECK(loom_texel_output_at(store, source_id, 0, &info) == LOOM_OK);
        CHECK(info.has_source);
        CHECK(info.source.data.size == 5);
        CHECK(memcmp(info.source.data.data, "hello", 5) == 0);
        loom_output_info_free(&info);
    }
    loom_store_close(store);
    remove(image);

    if (failures != 0) {
        fprintf(stderr, "%d checks failed\n", failures);
        return 1;
    }
    printf("abi smoke ok\n");
    return 0;
}
