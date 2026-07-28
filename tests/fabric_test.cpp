#include <stdio.h>
#include <string.h>

#include "fiber.h"
#include "key.h"
#include "node.h"
#include "node_id.h"
#include "port.h"
#include "seal.h"
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

static void test_value()
{
  Value empty;
  CHECK(empty.kind() == VALUE_EMPTY);

  Value flag(true);
  CHECK(flag.kind() == VALUE_BOOL);
  CHECK(flag.boolean());

  Value number(-42);
  CHECK(number.kind() == VALUE_INT);
  CHECK(number.integer() == -42);

  Value real(1.5);
  CHECK(real.kind() == VALUE_FLOAT);
  CHECK(real.real() == 1.5);

  Value text("hello");
  CHECK(text.kind() == VALUE_STRING);
  CHECK(text.text() == "hello");

  Byte raw[] = { 0x00, 0x01, 0xff };
  Value blob(raw, 3);
  CHECK(blob.kind() == VALUE_BYTES);
  CHECK(blob.bytes().size() == 3);
  CHECK(blob.bytes()[2] == 0xff);

  CHECK(flag.equals(Value(true)));
  CHECK(!flag.equals(Value(false)));

  Value copy = text;
  CHECK(copy.equals(text));
  CHECK(copy.text() == "hello");

  Value assigned;
  assigned = blob;
  CHECK(assigned.equals(blob));
  CHECK(assigned.bytes().size() == 3);

  assigned = number;
  CHECK(assigned.kind() == VALUE_INT);
  CHECK(assigned.integer() == -42);

  assigned = Value();
  CHECK(assigned.kind() == VALUE_EMPTY);
}

static void test_node_id_identity_not_address()
{
  NodeId unset;
  CHECK(unset.is_unset());

  Byte raw[NodeId::SIZE];
  memset(raw, 0, NodeId::SIZE);
  raw[0] = 0xab;
  raw[31] = 0xcd;

  NodeId a;
  a.set_bytes(raw);
  CHECK(!a.is_unset());

  NodeId b;
  b.set_bytes(raw);
  CHECK(a.equals(b));

  raw[1] = 0x01;
  NodeId c;
  c.set_bytes(raw);
  CHECK(!a.equals(c));
  CHECK(a.less_than(c) || c.less_than(a));
}

static void test_node_ports_hold_values()
{
  Node node;
  CHECK(node.id().is_unset());
  CHECK(node.size() == 0);

  Byte id_bytes[NodeId::SIZE];
  memset(id_bytes, 0, NodeId::SIZE);
  id_bytes[0] = 1;
  NodeId id;
  id.set_bytes(id_bytes);
  node.set_id(id);
  CHECK(node.id().equals(id));

  Port out("body", PORT_OUT, Value("hello"));
  Port in("text", PORT_IN);
  in.set_value(Value(7));

  CHECK(node.put(out));
  CHECK(node.put(in));
  CHECK(node.size() == 2);
  CHECK(node.has("body"));
  CHECK(!node.has("missing"));

  Port got;
  CHECK(node.get("body", &got));
  CHECK(got.name() == "body");
  CHECK(got.direction() == PORT_OUT);
  CHECK(got.value().kind() == VALUE_STRING);
  CHECK(got.value().text() == "hello");

  CHECK(node.get("text", &got));
  CHECK(got.value().integer() == 7);

  Byte payload[] = { 1, 2, 3 };
  got.set_value(Value(payload, 3));
  CHECK(node.put(got));
  CHECK(node.get("text", &got));
  CHECK(got.value().bytes().size() == 3);

  CHECK(node.remove("body"));
  CHECK(!node.has("body"));
  CHECK(node.size() == 1);
}

static void test_fiber()
{
  Byte raw_a[NodeId::SIZE];
  Byte raw_b[NodeId::SIZE];
  memset(raw_a, 0, NodeId::SIZE);
  memset(raw_b, 0, NodeId::SIZE);
  raw_a[0] = 1;
  raw_b[0] = 2;

  NodeId a;
  NodeId b;
  a.set_bytes(raw_a);
  b.set_bytes(raw_b);

  Fiber fiber;
  fiber.set_source(a, "out");
  fiber.set_target(b, "in");
  CHECK(fiber.source().equals(a));
  CHECK(fiber.target().equals(b));
  CHECK(fiber.source_port() == "out");
  CHECK(fiber.target_port() == "in");
}

static void test_crypto_auth()
{
  KeyPair keys;
  CHECK(keys.public_key().is_unset());
  CHECK(keys.generate());
  CHECK(!keys.public_key().is_unset());

  Bytes sealed;
  Bytes plain;
  Byte  msg[] = { 1, 2, 3 };
  Byte  signature[SIGNATURE_SIZE];
  memset(signature, 0, SIGNATURE_SIZE);

  CHECK(seal(msg, 3, keys.secret_bytes(), KEY_SIZE, &sealed));
  CHECK(sealed.size() > 3);
  CHECK(unseal(sealed.data(), sealed.size(), keys.secret_bytes(), KEY_SIZE,
               &plain));
  CHECK(plain.size() == 3);
  CHECK(plain[0] == 1 && plain[1] == 2 && plain[2] == 3);

  KeyPair other;
  CHECK(other.generate());
  CHECK(!unseal(sealed.data(), sealed.size(), other.secret_bytes(), KEY_SIZE,
                &plain));

  CHECK(sign(msg, 3, keys, signature));
  CHECK(verify(msg, 3, keys.public_key(), signature));
  CHECK(!verify(msg, 3, other.public_key(), signature));
}

int main()
{
  test_value();
  test_node_id_identity_not_address();
  test_node_ports_hold_values();
  test_fiber();
  test_crypto_auth();

  if (failures != 0) {
    fprintf(stderr, "%d checks failed\n", failures);
    return 1;
  }

  printf("ok\n");
  return 0;
}
