#include <stdio.h>
#include <string.h>

#include "fiber.h"
#include "memory_volume.h"
#include "node.h"
#include "node_id.h"
#include "port.h"
#include "principal.h"
#include "store.h"
#include "value.h"

using namespace lucia;

static int failures = 0;

#define CHECK(condition)                                                     \
  do {                                                                       \
    if (!(condition)) {                                                      \
      fprintf(stderr, "fail: %s (%s:%d)\n", #condition, __FILE__, __LINE__); \
      ++failures;                                                            \
    }                                                                        \
  } while (0)

static NodeId make_id(Byte marker)
{
  Byte raw[NodeId::SIZE];
  memset(raw, 0, NodeId::SIZE);
  raw[0] = marker;
  NodeId id;
  id.set_bytes(raw);
  return id;
}

static void test_store_round_trip()
{
  Principal alice;
  CHECK(alice.create());

  MemoryVolume volume(16);
  Store store;
  CHECK(store.create(&volume, alice));
  CHECK(store.is_open());
  CHECK(store.node_count() == 0);

  Node message;
  message.set_id(make_id(1));
  CHECK(message.put(Port("body", PORT_OUT, Value("hello bob"))));
  CHECK(message.put(Port("to", PORT_IN, Value(2))));

  Node keyboard;
  keyboard.set_id(make_id(2));
  CHECK(keyboard.put(Port("text", PORT_OUT, Value("hello bob"))));

  CHECK(store.put_node(message));
  CHECK(store.put_node(keyboard));

  Fiber fiber;
  fiber.set_source(keyboard.id(), "text");
  fiber.set_target(message.id(), "body");
  CHECK(store.put_fiber(fiber));
  CHECK(store.node_count() == 2);
  CHECK(store.fiber_count() == 1);
  CHECK(store.flush());

  Store reopened;
  CHECK(reopened.open(&volume, alice));
  CHECK(reopened.node_count() == 2);
  CHECK(reopened.fiber_count() == 1);

  Node loaded;
  CHECK(reopened.get_node(message.id(), &loaded));
  CHECK(loaded.size() == 2);

  Port body;
  CHECK(loaded.get("body", &body));
  CHECK(body.direction() == PORT_OUT);
  CHECK(body.value().text() == "hello bob");

  Port to;
  CHECK(loaded.get("to", &to));
  CHECK(to.value().integer() == 2);

  Fiber loaded_fiber;
  CHECK(reopened.fiber_at(0, &loaded_fiber));
  CHECK(loaded_fiber.source().equals(keyboard.id()));
  CHECK(loaded_fiber.source_port() == "text");
  CHECK(loaded_fiber.target().equals(message.id()));
  CHECK(loaded_fiber.target_port() == "body");
}

static void test_store_rejects_wrong_principal()
{
  Principal alice;
  Principal bob;
  CHECK(alice.create());
  CHECK(bob.create());

  MemoryVolume volume(8);
  Store store;
  CHECK(store.create(&volume, alice));

  Node node;
  node.set_id(make_id(9));
  CHECK(node.put(Port("x", PORT_OUT, Value(true))));
  CHECK(store.put_node(node));
  CHECK(store.flush());

  Store as_bob;
  CHECK(!as_bob.open(&volume, bob));
  CHECK(!as_bob.is_open());

  Store as_alice;
  CHECK(as_alice.open(&volume, alice));
  CHECK(as_alice.has_node(node.id()));
}

static void test_seal_rejects_wrong_key()
{
  Principal alice;
  CHECK(alice.create());

  MemoryVolume volume(8);
  Store store;
  CHECK(store.create(&volume, alice));

  Node node;
  node.set_id(make_id(3));
  CHECK(node.put(Port("n", PORT_IN, Value(42))));
  CHECK(store.put_node(node));
  CHECK(store.flush());

  // Same public identity bytes are bound in the header; a fresh principal
  // cannot open.  Covered above.  Tamper the sealed body and reopen fails.
  Byte page[PAGE_SIZE];
  CHECK(volume.read(1, page));
  page[0] = (Byte)(page[0] ^ 0xff);
  CHECK(volume.write(1, page));
  CHECK(volume.flush());

  Store broken;
  CHECK(!broken.open(&volume, alice));
}

int main()
{
  test_store_round_trip();
  test_store_rejects_wrong_principal();
  test_seal_rejects_wrong_key();

  if (failures != 0) {
    fprintf(stderr, "%d checks failed\n", failures);
    return 1;
  }

  printf("ok\n");
  return 0;
}
