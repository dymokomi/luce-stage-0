#include <stdio.h>

#include "fabric/persistence/store.h"
#include "loom/evaluation/fiber_index.h"
#include "loom/evaluation/spool.h"
#include "storage/volume/memory_volume.h"

using namespace lucia;

static int failures = 0;

#define CHECK(condition)                                                                   \
    do {                                                                                   \
        if (!(condition)) {                                                                \
            fprintf(stderr, "fail: %s (%s:%d)\n", #condition, __FILE__, __LINE__);         \
            ++failures;                                                                    \
        }                                                                                  \
    } while (0)

class ConcatEvaluator : public Evaluator {
public:
    ConcatEvaluator() : calls(0) {}

    void evaluate(const Texel &, const ValueOutcomeMap &inputs,
                  ValueOutcomeMap *outputs) override {
        ++calls;
        ValueOutcomeMap::const_iterator left  = inputs.find("left");
        ValueOutcomeMap::const_iterator right = inputs.find("right");
        if (left == inputs.end() || right == inputs.end() ||
            left->second.status() != VALUE_AVAILABLE ||
            right->second.status() != VALUE_AVAILABLE) {
            (*outputs)["value"] = ValueOutcome::unavailable();
            return;
        }
        const String joined = left->second.value().text() + right->second.value().text();
        (*outputs)["value"] = ValueOutcome::available(Value(joined));
    }

    int calls;
};

static Texel source(const char *text) {
    TexelId id;
    id.generate();
    Texel      texel(id);
    OutputPort output("value", VALUE_TEXT);
    output.set_source(Value(text));
    texel.put_output(output);
    return texel;
}

static void test_pull_cache_and_invalidation() {
    MemoryVolume volume(32);
    Store        store;
    CHECK(store.create(&volume));

    Texel left      = source("hello ");
    Texel right     = source("world");
    Texel unrelated = source("unused");

    TexelId joined_id;
    CHECK(joined_id.generate());
    Texel joined(joined_id);
    CHECK(joined.set_evaluator("concat"));
    CHECK(joined.put_input(InputPort("left", VALUE_TEXT)));
    CHECK(joined.put_input(InputPort("right", VALUE_TEXT)));
    CHECK(joined.put_output(OutputPort("value", VALUE_TEXT)));

    Transaction transaction;
    CHECK(store.begin(&transaction));
    CHECK(transaction.put(left));
    CHECK(transaction.put(right));
    CHECK(transaction.put(unrelated));
    CHECK(transaction.put(joined));
    CHECK(transaction.connect(joined.id(), "left", left.id(), "value"));
    CHECK(transaction.connect(joined.id(), "right", right.id(), "value"));
    CHECK(transaction.commit());

    ConcatEvaluator   concat;
    EvaluatorRegistry registry;
    CHECK(registry.put("concat", &concat));
    Spool spool(&store, &registry);

    ValueOutcome outcome;
    CHECK(spool.demand(joined.id(), "value", &outcome));
    CHECK(outcome.status() == VALUE_AVAILABLE);
    CHECK(outcome.value().text() == "hello world");
    CHECK(concat.calls == 1);

    CHECK(spool.demand(joined.id(), "value", &outcome));
    CHECK(concat.calls == 1);

    CHECK(store.begin(&transaction));
    CHECK(transaction.get(left.id(), &left));
    OutputPort output;
    CHECK(left.get_output("value", &output));
    CHECK(output.set_source(Value("goodbye ")));
    CHECK(left.put_output(output));
    CHECK(transaction.put(left));
    CHECK(transaction.commit());

    CHECK(spool.demand(joined.id(), "value", &outcome));
    CHECK(outcome.value().text() == "goodbye world");
    CHECK(concat.calls == 2);

    CHECK(store.begin(&transaction));
    CHECK(transaction.get(unrelated.id(), &unrelated));
    CHECK(unrelated.get_output("value", &output));
    CHECK(output.set_source(Value("changed")));
    CHECK(unrelated.put_output(output));
    CHECK(transaction.put(unrelated));
    CHECK(transaction.commit());

    CHECK(spool.demand(joined.id(), "value", &outcome));
    CHECK(concat.calls == 2);
}

static void test_advance_keeps_clean_cache() {
    MemoryVolume volume(32);
    Store        store;
    CHECK(store.create(&volume));

    Texel left      = source("push ");
    Texel right     = source("pull");
    Texel unrelated = source("elsewhere");

    TexelId joined_id;
    CHECK(joined_id.generate());
    Texel joined(joined_id);
    CHECK(joined.set_evaluator("concat"));
    CHECK(joined.put_input(InputPort("left", VALUE_TEXT)));
    CHECK(joined.put_input(InputPort("right", VALUE_TEXT)));
    CHECK(joined.put_output(OutputPort("value", VALUE_TEXT)));

    Transaction transaction;
    CHECK(store.begin(&transaction));
    CHECK(transaction.put(left));
    CHECK(transaction.put(right));
    CHECK(transaction.put(unrelated));
    CHECK(transaction.put(joined));
    CHECK(transaction.connect(joined.id(), "left", left.id(), "value"));
    CHECK(transaction.connect(joined.id(), "right", right.id(), "value"));
    CHECK(transaction.commit());

    ConcatEvaluator   concat;
    EvaluatorRegistry registry;
    CHECK(registry.put("concat", &concat));
    Spool      spool(&store, &registry);
    FiberIndex index;
    CHECK(index.build(&store));

    U64          seen = store.generation();
    ValueOutcome outcome;
    CHECK(spool.demand(joined.id(), "value", &outcome));
    CHECK(outcome.value().text() == "push pull");
    CHECK(concat.calls == 1);

    // An unrelated commit: reconcile stamps the clean records and the
    // next demand touches nothing.
    CHECK(store.begin(&transaction));
    CHECK(transaction.get(unrelated.id(), &unrelated));
    OutputPort output;
    CHECK(unrelated.get_output("value", &output));
    CHECK(output.set_source(Value("moved")));
    CHECK(unrelated.put_output(output));
    CHECK(transaction.put(unrelated));
    CHECK(transaction.commit());

    TexelIdList changed;
    TexelIdSet  dirty;
    CHECK(store.changes_since(seen, &changed));
    CHECK(index.apply(&store, changed));
    CHECK(index.downstream(changed, &dirty));
    CHECK(dirty.size() == 1);
    spool.advance(seen, store.generation(), dirty);
    seen = store.generation();

    CHECK(spool.demand(joined.id(), "value", &outcome));
    CHECK(concat.calls == 1);

    // An upstream observation: the dirty closure reaches the join, and
    // only that path recomputes on demand.
    CHECK(store.observe(left.id(), "value", Value("observed ")));
    CHECK(store.changes_since(seen, &changed));
    CHECK(index.apply(&store, changed));
    CHECK(index.downstream(changed, &dirty));
    CHECK(dirty.find(joined.id()) != dirty.end());
    spool.advance(seen, store.generation(), dirty);
    seen = store.generation();

    CHECK(spool.demand(joined.id(), "value", &outcome));
    CHECK(outcome.value().text() == "observed pull");
    CHECK(concat.calls == 2);
}

int main() {
    test_pull_cache_and_invalidation();
    test_advance_keeps_clean_cache();

    if (failures != 0) {
        fprintf(stderr, "%d checks failed\n", failures);
        return 1;
    }
    printf("ok\n");
    return 0;
}
