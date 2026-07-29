#include <stdio.h>

#include "fabric/persistence/store.h"
#include "loom/evaluation/fiber_index.h"
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

static Texel source(const char *text) {
    TexelId id;
    id.generate();
    Texel      texel(id);
    OutputPort output("value", VALUE_TEXT);
    output.set_source(Value(text));
    texel.put_output(output);
    return texel;
}

static void test_build_apply_downstream() {
    MemoryVolume volume(32);
    Store        store;
    CHECK(store.create(&volume));

    Texel left  = source("left");
    Texel right = source("right");

    TexelId join_id;
    CHECK(join_id.generate());
    Texel join(join_id);
    CHECK(join.set_evaluator("concat"));
    CHECK(join.put_input(InputPort("left", VALUE_TEXT)));
    CHECK(join.put_input(InputPort("right", VALUE_TEXT)));
    CHECK(join.put_output(OutputPort("value", VALUE_TEXT)));

    TexelId upper_id;
    CHECK(upper_id.generate());
    Texel upper(upper_id);
    CHECK(upper.set_evaluator("upper"));
    CHECK(upper.put_input(InputPort("text", VALUE_TEXT)));
    CHECK(upper.put_output(OutputPort("value", VALUE_TEXT)));

    Transaction transaction;
    CHECK(store.begin(&transaction));
    CHECK(transaction.put(left));
    CHECK(transaction.put(right));
    CHECK(transaction.put(join));
    CHECK(transaction.put(upper));
    CHECK(transaction.connect(join_id, "left", left.id(), "value"));
    CHECK(transaction.connect(join_id, "right", right.id(), "value"));
    CHECK(transaction.connect(upper_id, "text", join_id, "value"));
    CHECK(transaction.commit());

    FiberIndex index;
    CHECK(index.build(&store));
    CHECK(index.size() == 2);

    // A changed source dirties its whole downstream chain and only that.
    TexelIdList changed;
    TexelIdSet  dirty;
    changed.push_back(left.id());
    CHECK(index.downstream(changed, &dirty));
    CHECK(dirty.size() == 3);
    CHECK(dirty.find(left.id()) != dirty.end());
    CHECK(dirty.find(join_id) != dirty.end());
    CHECK(dirty.find(upper_id) != dirty.end());
    CHECK(dirty.find(right.id()) == dirty.end());

    // A changed sink dirties only itself.
    changed.clear();
    changed.push_back(upper_id);
    CHECK(index.downstream(changed, &dirty));
    CHECK(dirty.size() == 1);

    // Disconnecting rewrites the consumer, so the delta names it; apply
    // relearns the row and left loses its downstream chain.
    CHECK(store.begin(&transaction));
    CHECK(transaction.disconnect(join_id, "left"));
    CHECK(transaction.commit());
    changed.clear();
    changed.push_back(join_id);
    CHECK(index.apply(&store, changed));

    changed.clear();
    changed.push_back(left.id());
    CHECK(index.downstream(changed, &dirty));
    CHECK(dirty.size() == 1);
    changed.clear();
    changed.push_back(right.id());
    CHECK(index.downstream(changed, &dirty));
    CHECK(dirty.size() == 3);

    // Removing a consumer drops its edges entirely.
    CHECK(store.begin(&transaction));
    CHECK(transaction.remove(upper_id));
    CHECK(transaction.commit());
    changed.clear();
    changed.push_back(upper_id);
    CHECK(index.apply(&store, changed));
    CHECK(index.size() == 1);
    changed.clear();
    changed.push_back(join_id);
    CHECK(index.downstream(changed, &dirty));
    CHECK(dirty.size() == 1);

    // A rebuilt index agrees with the applied one.
    FiberIndex rebuilt;
    CHECK(rebuilt.build(&store));
    CHECK(rebuilt.size() == index.size());
}

int main() {
    test_build_apply_downstream();

    if (failures != 0) {
        fprintf(stderr, "%d checks failed\n", failures);
        return 1;
    }
    printf("ok\n");
    return 0;
}
