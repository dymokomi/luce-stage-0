#include <stdio.h>

#include "loom/organization/arrangement.h"
#include "storage/volume/memory_volume.h"

using namespace lucia;

static int failures = 0;

#define CHECK(condition)                                                                   \
  do {                                                                                     \
    if (!(condition)) {                                                                    \
      fprintf(stderr, "fail: %s (%s:%d)\n", #condition, __FILE__, __LINE__);               \
      ++failures;                                                                          \
    }                                                                                      \
  } while (0)

static void test_multi_context_arrangements() {
  MemoryVolume volume(64);
  Store        store;
  CHECK(store.create(&volume));

  TexelId material_id;
  TexelId first_id;
  TexelId second_id;
  CHECK(material_id.generate());
  CHECK(first_id.generate());
  CHECK(second_id.generate());

  Texel material(material_id);
  CHECK(material.set_content(Value("shared material")));

  Texel first;
  Texel second;
  CHECK(create_arrangement(first_id, &first));
  CHECK(create_arrangement(second_id, &second));

  CHECK(arrangement_add(&first, "draft", material_id));
  CHECK(arrangement_add(&first, "source", material_id));
  CHECK(arrangement_add(&second, "asset", material_id));
  CHECK(arrangement_add(&second, "preview", material_id));

  Transaction transaction;
  CHECK(store.begin(&transaction));
  CHECK(transaction.put(material));
  CHECK(transaction.put(first));
  CHECK(transaction.put(second));
  CHECK(transaction.commit());

  CHECK(validate_arrangement(first, store));
  CHECK(validate_arrangement(second, store));

  CHECK(store.begin(&transaction));
  CHECK(transaction.get(first_id, &first));
  CHECK(arrangement_rename(&first, "draft", "chapter"));
  CHECK(arrangement_reorder(&first, "source", 0));
  CHECK(transaction.put(first));
  CHECK(transaction.commit());

  CHECK(store.begin(&transaction));
  CHECK(transaction.get(second_id, &second));
  CHECK(arrangement_rename(&second, "preview", "cover"));
  CHECK(arrangement_reorder(&second, "cover", 0));
  CHECK(transaction.put(second));
  CHECK(transaction.commit());

  Store reopened;
  CHECK(reopened.open(&volume));
  CHECK(reopened.get(first_id, &first));
  CHECK(reopened.get(second_id, &second));
  CHECK(reopened.get(material_id, &material));
  CHECK(material.id().equals(material_id));
  CHECK(material.content().text() == "shared material");

  ArrangementEntries entries;
  CHECK(inspect_arrangement(first, &entries));
  CHECK(entries.size() == 2);
  CHECK(entries[0].name == "source");
  CHECK(entries[1].name == "chapter");
  CHECK(entries[0].texel.equals(material_id));
  CHECK(entries[1].texel.equals(material_id));

  CHECK(inspect_arrangement(second, &entries));
  CHECK(entries.size() == 2);
  CHECK(entries[0].name == "cover");
  CHECK(entries[1].name == "asset");
  CHECK(entries[0].texel.equals(material_id));
  CHECK(entries[1].texel.equals(material_id));
  CHECK(validate_arrangement(first, reopened));
  CHECK(validate_arrangement(second, reopened));

  CHECK(arrangement_remove(&first, "source"));
  CHECK(inspect_arrangement(first, &entries));
  CHECK(entries.size() == 1);
  CHECK(entries[0].name == "chapter");
  CHECK(entries[0].texel.equals(material_id));
}

static void test_rejected_arrangements() {
  TexelId arrangement_id;
  TexelId material_id;
  CHECK(arrangement_id.generate());
  CHECK(material_id.generate());

  Texel arrangement;
  CHECK(create_arrangement(arrangement_id, &arrangement));
  CHECK(arrangement_add(&arrangement, "item", material_id));
  CHECK(!arrangement_add(&arrangement, "item", material_id));

  TexelId unset;
  CHECK(!arrangement_add(&arrangement, "unset", unset));

  String long_name(ARRANGEMENT_MAX_NAME_SIZE + 1, 'x');
  CHECK(!arrangement_add(&arrangement, long_name.c_str(), material_id));

  Bytes malformed = arrangement.content().bytes();
  malformed.push_back(0);
  Texel trailing(arrangement_id);
  CHECK(trailing.set_content(Value(malformed)));
  ArrangementEntries entries;
  CHECK(!inspect_arrangement(trailing, &entries));

  Bytes excessive(ARRANGEMENT_MAX_CONTENT_SIZE + 1, 0);
  Texel oversized(arrangement_id);
  CHECK(oversized.set_content(Value(excessive)));
  CHECK(!inspect_arrangement(oversized, &entries));

  MemoryVolume volume(32);
  Store        store;
  CHECK(store.create(&volume));
  Transaction transaction;
  CHECK(store.begin(&transaction));
  CHECK(transaction.put(arrangement));
  CHECK(transaction.commit());
  CHECK(!validate_arrangement(arrangement, store));
}

int main() {
  test_multi_context_arrangements();
  test_rejected_arrangements();

  if (failures != 0) {
    fprintf(stderr, "%d checks failed\n", failures);
    return 1;
  }
  printf("ok\n");
  return 0;
}
