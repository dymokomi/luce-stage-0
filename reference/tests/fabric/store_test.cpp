#include <stdio.h>
#include <string.h>

#include "fabric/persistence/encode.h"
#include "fabric/persistence/store.h"
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

class FaultVolume : public Volume {
public:
    explicit FaultVolume(U64 pages)
        : memory(pages), writes(0), fail_write(0), fail_flush(false) {}

    U64 size() const override {
        return memory.size();
    }

    bool read(U64 page, void *destination) override {
        return memory.read(page, destination);
    }

    bool write(U64 page, const void *source) override {
        ++writes;
        if (fail_write != 0 && writes == fail_write) {
            return false;
        }
        return memory.write(page, source);
    }

    bool flush() override {
        return !fail_flush && memory.flush();
    }

    void fail_on_write(U64 write) {
        writes     = 0;
        fail_write = write;
    }

    void succeed() {
        writes     = 0;
        fail_write = 0;
        fail_flush = false;
    }

private:
    MemoryVolume memory;
    U64          writes;
    U64          fail_write;
    bool         fail_flush;
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

static Texel computed(const char *evaluator) {
    TexelId id;
    id.generate();
    Texel texel(id);
    texel.set_evaluator(evaluator);
    texel.put_input(InputPort("input", VALUE_TEXT));
    texel.put_output(OutputPort("value", VALUE_TEXT));
    return texel;
}

static void test_encode_round_trip() {
    Texel     one = source("hello");
    Texel     two = computed("copy");
    InputPort input;
    CHECK(two.get_input("input", &input));
    CHECK(input.bind(Fiber(one.id(), "value")));
    CHECK(two.put_input(input));

    Texels texels;
    texels.push_back(one);
    texels.push_back(two);
    BlobRecords blobs;
    Bytes       encoded;
    CHECK(encode_snapshot(texels, blobs, &encoded));

    Texels      decoded;
    BlobRecords decoded_blobs;
    CHECK(decode_snapshot(encoded.data(), encoded.size(), &decoded, &decoded_blobs));
    CHECK(decoded.size() == 2);
    CHECK(decoded_blobs.empty());

    encoded.push_back(0);
    CHECK(!decode_snapshot(encoded.data(), encoded.size(), &decoded, &decoded_blobs));
}

static void test_transaction_blob_fanout_and_reopen() {
    MemoryVolume volume(32);
    Store        store;
    CHECK(store.create(&volume));
    const U64 initial_generation = store.generation();

    Texel material = source("material");
    Texel first    = computed("copy");
    Texel second   = computed("copy");

    Bytes       large(PAGE_SIZE * 2 + 17, 0x5a);
    Transaction transaction;
    CHECK(store.begin(&transaction));
    BlobRef blob;
    CHECK(transaction.put_blob(large, &blob));
    CHECK(material.set_content(Value(blob)));
    CHECK(transaction.put(material));
    CHECK(transaction.put(first));
    CHECK(transaction.put(second));
    CHECK(transaction.connect(first.id(), "input", material.id(), "value"));
    CHECK(transaction.connect(second.id(), "input", material.id(), "value"));
    CHECK(store.size() == 0);
    CHECK(transaction.commit());
    CHECK(store.generation() == initial_generation + 1);
    CHECK(store.size() == 3);

    Store reopened;
    CHECK(reopened.open(&volume));
    CHECK(reopened.generation() == store.generation());
    CHECK(reopened.has(material.id()));
    Bytes loaded;
    CHECK(reopened.get_blob(blob, &loaded));
    CHECK(loaded == large);

    Texel loaded_material;
    CHECK(reopened.get(material.id(), &loaded_material));
    CHECK(loaded_material.id().equals(material.id()));
    CHECK(loaded_material.content().blob().equals(blob));
}

static void test_rejects_cycle_and_dangling_reference() {
    MemoryVolume volume(32);
    Store        store;
    CHECK(store.create(&volume));

    Texel       first  = computed("copy");
    Texel       second = computed("copy");
    Transaction transaction;
    CHECK(store.begin(&transaction));
    CHECK(transaction.put(first));
    CHECK(transaction.put(second));
    CHECK(transaction.connect(first.id(), "input", second.id(), "value"));
    CHECK(transaction.connect(second.id(), "input", first.id(), "value"));
    CHECK(!transaction.commit());
    CHECK(transaction.abort());
    CHECK(store.size() == 0);

    TexelId missing;
    missing.generate();
    Texel bad = source("bad");
    CHECK(bad.set_content(Value(missing)));
    CHECK(store.begin(&transaction));
    CHECK(transaction.put(bad));
    CHECK(!transaction.commit());
    CHECK(transaction.abort());
}

static void test_failed_publish_keeps_previous_generation() {
    FaultVolume volume(32);
    Store       store;
    CHECK(store.create(&volume));

    Texel       durable = source("old");
    Transaction transaction;
    CHECK(store.begin(&transaction));
    CHECK(transaction.put(durable));
    CHECK(transaction.commit());
    const U64 generation = store.generation();

    Texel replacement = source("new");
    CHECK(store.begin(&transaction));
    CHECK(transaction.put(replacement));
    volume.fail_on_write(2);
    CHECK(!transaction.commit());
    CHECK(store.generation() == generation);
    CHECK(store.has(durable.id()));
    CHECK(!store.has(replacement.id()));
    CHECK(transaction.abort());

    volume.succeed();
    Store reopened;
    CHECK(reopened.open(&volume));
    CHECK(reopened.generation() == generation);
    CHECK(reopened.has(durable.id()));
    CHECK(!reopened.has(replacement.id()));
}

static bool contains(const TexelIdList &list, const TexelId &id) {
    for (Size i = 0; i < list.size(); ++i) {
        if (list[i].equals(id)) {
            return true;
        }
    }
    return false;
}

static void test_changes_since_ring() {
    MemoryVolume volume(32);
    Store        store;
    CHECK(store.create(&volume));

    const U64   base = store.generation();
    TexelIdList changed;
    CHECK(store.changes_since(base, &changed));
    CHECK(changed.empty());
    CHECK(!store.changes_since(base + 1, &changed));

    Texel       one = source("one");
    Texel       two = source("two");
    Transaction transaction;
    CHECK(store.begin(&transaction));
    CHECK(transaction.put(one));
    CHECK(transaction.commit());
    CHECK(store.begin(&transaction));
    CHECK(transaction.put(two));
    CHECK(transaction.commit());

    CHECK(store.changes_since(base, &changed));
    CHECK(changed.size() == 2);
    CHECK(contains(changed, one.id()));
    CHECK(contains(changed, two.id()));

    CHECK(store.changes_since(base + 1, &changed));
    CHECK(changed.size() == 1);
    CHECK(contains(changed, two.id()));

    // Removal is a change too.
    CHECK(store.begin(&transaction));
    CHECK(transaction.remove(two.id()));
    CHECK(transaction.commit());
    CHECK(store.changes_since(base + 2, &changed));
    CHECK(changed.size() == 1);
    CHECK(contains(changed, two.id()));

    // Push the ring past capacity; the old baseline loses coverage.
    for (int i = 0; i < Store::CHANGE_RING + 4; ++i) {
        CHECK(store.begin(&transaction));
        CHECK(transaction.get(one.id(), &one));
        OutputPort output;
        CHECK(one.get_output("value", &output));
        CHECK(output.set_source(Value("again")));
        CHECK(one.put_output(output));
        CHECK(transaction.put(one));
        CHECK(transaction.commit());
    }
    CHECK(!store.changes_since(base, &changed));
    CHECK(store.changes_since(store.generation() - 1, &changed));
    CHECK(changed.size() == 1);
    CHECK(contains(changed, one.id()));
}

static void test_observe_stays_volatile() {
    MemoryVolume volume(32);
    Store        store;
    CHECK(store.create(&volume));

    Texel       eye = source("seen");
    Transaction transaction;
    CHECK(store.begin(&transaction));
    CHECK(transaction.put(eye));
    CHECK(transaction.commit());

    Texel before;
    CHECK(store.get(eye.id(), &before));
    const U64 durable      = store.generation();
    const U64 pre_revision = before.revision();

    CHECK(store.observe(eye.id(), "value", Value("newer")));
    CHECK(store.generation() == durable + 1);

    Texel observed;
    CHECK(store.get(eye.id(), &observed));
    OutputPort output;
    CHECK(observed.get_output("value", &output));
    CHECK(output.source().text() == "newer");
    CHECK(observed.revision() > pre_revision);

    TexelIdList changed;
    CHECK(store.changes_since(durable, &changed));
    CHECK(changed.size() == 1);
    CHECK(contains(changed, eye.id()));

    // Wrong type, missing output, and missing texel all refuse.
    CHECK(!store.observe(eye.id(), "value", Value(true)));
    CHECK(!store.observe(eye.id(), "missing", Value("x")));
    TexelId absent;
    CHECK(absent.generate());
    CHECK(!store.observe(absent, "value", Value("x")));

    // A transaction begun before an observation cannot commit over it.
    CHECK(store.begin(&transaction));
    CHECK(store.observe(eye.id(), "value", Value("race")));
    CHECK(!transaction.commit());
    CHECK(transaction.abort());

    // Reopen: the observation is gone, the durable value remains.
    Store reopened;
    CHECK(reopened.open(&volume));
    Texel durable_texel;
    CHECK(reopened.get(eye.id(), &durable_texel));
    CHECK(durable_texel.get_output("value", &output));
    CHECK(output.source().text() == "seen");
}

int main() {
    test_encode_round_trip();
    test_transaction_blob_fanout_and_reopen();
    test_rejects_cycle_and_dangling_reference();
    test_failed_publish_keeps_previous_generation();
    test_changes_since_ring();
    test_observe_stays_volatile();

    if (failures != 0) {
        fprintf(stderr, "%d checks failed\n", failures);
        return 1;
    }
    printf("ok\n");
    return 0;
}
