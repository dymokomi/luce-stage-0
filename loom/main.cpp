#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "fiber.h"
#include "file_volume.h"
#include "node.h"
#include "node_id.h"
#include "port.h"
#include "principal.h"
#include "store.h"
#include "value.h"

using namespace lucia;

namespace {

enum { DEFAULT_PAGES = 64 };

const char* default_image = "loom.img";
const char* default_key   = "loom.key";

void print_usage()
{
  fprintf(stderr,
          "usage:\n"
          "  loom init   [--image PATH] [--key PATH] [--pages N]\n"
          "  loom status [--image PATH] [--key PATH]\n"
          "  loom list   [--image PATH] [--key PATH]\n"
          "  loom show   <id> [--image PATH] [--key PATH]\n"
          "  loom put    <id> <port> <text> [--image PATH] [--key PATH]\n"
          "  loom demo   [--image PATH] [--key PATH]\n"
          "\n"
          "id is two hex digits for the first byte (rest zero), e.g. 01\n"
          "defaults: --image loom.img --key loom.key --pages %d\n",
          DEFAULT_PAGES);
}

bool parse_hex_byte(const char* text, Byte* value)
{
  if (text == 0 || value == 0 || strlen(text) != 2) {
    return false;
  }

  unsigned int parsed = 0;
  if (sscanf(text, "%02x", &parsed) != 1 &&
      sscanf(text, "%02X", &parsed) != 1) {
    return false;
  }
  *value = (Byte)parsed;
  return true;
}

NodeId make_id(Byte marker)
{
  Byte raw[NodeId::SIZE];
  memset(raw, 0, NodeId::SIZE);
  raw[0] = marker;
  NodeId id;
  id.set_bytes(raw);
  return id;
}

void print_id(const NodeId& id)
{
  const Byte* bytes = id.bytes();
  for (Size i = 0; i < NodeId::SIZE; ++i) {
    printf("%02x", bytes[i]);
  }
}

void print_value(const Value& value)
{
  switch (value.kind()) {
  case VALUE_EMPTY:
    printf("(empty)");
    break;
  case VALUE_BOOL:
    printf(value.boolean() ? "true" : "false");
    break;
  case VALUE_INT:
    printf("%lld", (long long)value.integer());
    break;
  case VALUE_FLOAT:
    printf("%g", value.real());
    break;
  case VALUE_STRING:
    printf("\"%s\"", value.text().c_str());
    break;
  case VALUE_BYTES:
    printf("<%zu bytes>", value.bytes().size());
    break;
  }
}

bool save_key(const char* path, const Principal& who)
{
  FILE* file = fopen(path, "wb");
  if (file == 0) {
    fprintf(stderr, "loom: cannot write key %s\n", path);
    return false;
  }
  const Size wrote = fwrite(who.seal_key(), 1, KEY_SIZE, file);
  fclose(file);
  if (wrote != KEY_SIZE) {
    fprintf(stderr, "loom: short write for key %s\n", path);
    return false;
  }
  return true;
}

bool load_key(const char* path, Principal* who)
{
  if (who == 0) {
    return false;
  }

  FILE* file = fopen(path, "rb");
  if (file == 0) {
    fprintf(stderr, "loom: cannot read key %s\n", path);
    return false;
  }

  Byte secret[KEY_SIZE];
  const Size read_count = fread(secret, 1, KEY_SIZE, file);
  fclose(file);
  if (read_count != KEY_SIZE) {
    fprintf(stderr, "loom: key %s is not %d bytes\n", path, KEY_SIZE);
    return false;
  }
  return who->set_secret(secret);
}

bool open_store(const char* image_path, const char* key_path,
                FileVolume* volume, Principal* who, Store* store)
{
  if (!load_key(key_path, who)) {
    return false;
  }
  if (!volume->open(image_path)) {
    fprintf(stderr, "loom: cannot open image %s\n", image_path);
    return false;
  }
  if (!store->open(volume, *who)) {
    fprintf(stderr, "loom: cannot open fabric store (wrong key?)\n");
    return false;
  }
  return true;
}

int cmd_init(const char* image_path, const char* key_path, U64 pages)
{
  Principal who;
  if (!who.create()) {
    fprintf(stderr, "loom: key generate failed\n");
    return 1;
  }
  if (!save_key(key_path, who)) {
    return 1;
  }

  FileVolume volume;
  if (!volume.create(image_path, pages)) {
    fprintf(stderr, "loom: cannot create image %s\n", image_path);
    return 1;
  }

  Store store;
  if (!store.create(&volume, who)) {
    fprintf(stderr, "loom: cannot create fabric store\n");
    return 1;
  }

  printf("created %s (%llu pages) and %s\n", image_path,
         (unsigned long long)pages, key_path);
  return 0;
}

int cmd_status(const char* image_path, const char* key_path)
{
  FileVolume volume;
  Principal who;
  Store store;
  if (!open_store(image_path, key_path, &volume, &who, &store)) {
    return 1;
  }

  printf("image:  %s\n", image_path);
  printf("key:    %s\n", key_path);
  printf("pages:  %llu\n", (unsigned long long)volume.size());
  printf("nodes:  %zu\n", store.node_count());
  printf("fibers: %zu\n", store.fiber_count());
  return 0;
}

int cmd_list(const char* image_path, const char* key_path)
{
  FileVolume volume;
  Principal who;
  Store store;
  if (!open_store(image_path, key_path, &volume, &who, &store)) {
    return 1;
  }

  // Store does not expose node iteration yet — list via known demo ids and
  // report counts.  Full scan lands with journal/catalog work.
  printf("%zu nodes, %zu fibers\n", store.node_count(), store.fiber_count());

  for (int marker = 0; marker < 256; ++marker) {
    NodeId id = make_id((Byte)marker);
    if (!store.has_node(id)) {
      continue;
    }
    Node node;
    if (!store.get_node(id, &node)) {
      continue;
    }
    print_id(id);
    printf("  ports=%zu\n", node.size());
  }
  return 0;
}

int cmd_show(const char* image_path, const char* key_path, Byte marker)
{
  FileVolume volume;
  Principal who;
  Store store;
  if (!open_store(image_path, key_path, &volume, &who, &store)) {
    return 1;
  }

  NodeId id = make_id(marker);
  Node node;
  if (!store.get_node(id, &node)) {
    fprintf(stderr, "loom: node not found\n");
    return 1;
  }

  printf("id ");
  print_id(id);
  printf("\n");

  for (Size i = 0; i < node.size(); ++i) {
    Port port;
    if (!node.at(i, &port)) {
      return 1;
    }
    printf("  %s %s ", port.name().c_str(),
           port.direction() == PORT_OUT ? "out" : "in");
    print_value(port.value());
    printf("\n");
  }
  return 0;
}

int cmd_put(const char* image_path, const char* key_path, Byte marker,
            const char* port_name, const char* text)
{
  FileVolume volume;
  Principal who;
  Store store;
  if (!open_store(image_path, key_path, &volume, &who, &store)) {
    return 1;
  }

  NodeId id = make_id(marker);
  Node node;
  if (store.has_node(id)) {
    if (!store.get_node(id, &node)) {
      return 1;
    }
  } else {
    node.set_id(id);
  }

  if (!node.put(Port(port_name, PORT_OUT, Value(text)))) {
    fprintf(stderr, "loom: put port failed\n");
    return 1;
  }
  if (!store.put_node(node) || !store.flush()) {
    fprintf(stderr, "loom: store flush failed\n");
    return 1;
  }

  printf("put ");
  print_id(id);
  printf(" %s ", port_name);
  print_value(Value(text));
  printf("\n");
  return 0;
}

int cmd_demo(const char* image_path, const char* key_path)
{
  Principal who;
  FileVolume volume;
  Store store;

  FILE* key_file = fopen(key_path, "rb");
  if (key_file == 0) {
    if (cmd_init(image_path, key_path, DEFAULT_PAGES) != 0) {
      return 1;
    }
  } else {
    fclose(key_file);
  }

  if (!open_store(image_path, key_path, &volume, &who, &store)) {
    return 1;
  }

  Node message;
  message.set_id(make_id(0x01));
  message.put(Port("body", PORT_OUT, Value("hello bob")));
  message.put(Port("to", PORT_IN, Value("bob")));

  Node keyboard;
  keyboard.set_id(make_id(0x02));
  keyboard.put(Port("text", PORT_OUT, Value("hello bob")));

  Fiber fiber;
  fiber.set_source(keyboard.id(), "text");
  fiber.set_target(message.id(), "body");

  if (!store.put_node(message) || !store.put_node(keyboard)) {
    fprintf(stderr, "loom: demo write failed\n");
    return 1;
  }
  if (store.fiber_count() == 0) {
    if (!store.put_fiber(fiber)) {
      fprintf(stderr, "loom: demo fiber failed\n");
      return 1;
    }
  }
  if (!store.flush()) {
    fprintf(stderr, "loom: demo flush failed\n");
    return 1;
  }

  Store check;
  FileVolume reopened;
  Principal same;
  if (!open_store(image_path, key_path, &reopened, &same, &check)) {
    return 1;
  }

  Node loaded;
  if (!check.get_node(message.id(), &loaded)) {
    fprintf(stderr, "loom: demo reload failed\n");
    return 1;
  }

  Port body;
  if (!loaded.get("body", &body) || body.value().text() != "hello bob") {
    fprintf(stderr, "loom: demo body mismatch\n");
    return 1;
  }

  printf("demo ok\n");
  printf("  nodes=%zu fibers=%zu\n", check.node_count(), check.fiber_count());
  printf("  message 01 body ");
  print_value(body.value());
  printf("\n");
  return 0;
}

bool match_flag(const char* arg, const char* name)
{
  return arg != 0 && strcmp(arg, name) == 0;
}

}  // namespace

int main(int argc, char** argv)
{
  if (argc < 2) {
    print_usage();
    return 1;
  }

  const char* command = argv[1];
  const char* image_path = default_image;
  const char* key_path = default_key;
  U64 pages = DEFAULT_PAGES;
  Byte id_marker = 0;
  const char* port_name = 0;
  const char* text = 0;
  bool have_id = false;

  for (int i = 2; i < argc; ++i) {
    if (match_flag(argv[i], "--image") && i + 1 < argc) {
      image_path = argv[++i];
    } else if (match_flag(argv[i], "--key") && i + 1 < argc) {
      key_path = argv[++i];
    } else if (match_flag(argv[i], "--pages") && i + 1 < argc) {
      pages = (U64)strtoull(argv[++i], 0, 10);
      if (pages < 2) {
        fprintf(stderr, "loom: --pages must be >= 2\n");
        return 1;
      }
    } else if (!have_id && (strcmp(command, "show") == 0 ||
                            strcmp(command, "put") == 0)) {
      if (!parse_hex_byte(argv[i], &id_marker)) {
        fprintf(stderr, "loom: bad id '%s' (want two hex digits)\n", argv[i]);
        return 1;
      }
      have_id = true;
    } else if (strcmp(command, "put") == 0 && port_name == 0) {
      port_name = argv[i];
    } else if (strcmp(command, "put") == 0 && text == 0) {
      text = argv[i];
    } else {
      fprintf(stderr, "loom: unexpected argument '%s'\n", argv[i]);
      print_usage();
      return 1;
    }
  }

  if (strcmp(command, "init") == 0) {
    return cmd_init(image_path, key_path, pages);
  }
  if (strcmp(command, "status") == 0) {
    return cmd_status(image_path, key_path);
  }
  if (strcmp(command, "list") == 0) {
    return cmd_list(image_path, key_path);
  }
  if (strcmp(command, "show") == 0) {
    if (!have_id) {
      print_usage();
      return 1;
    }
    return cmd_show(image_path, key_path, id_marker);
  }
  if (strcmp(command, "put") == 0) {
    if (!have_id || port_name == 0 || text == 0) {
      print_usage();
      return 1;
    }
    return cmd_put(image_path, key_path, id_marker, port_name, text);
  }
  if (strcmp(command, "demo") == 0) {
    return cmd_demo(image_path, key_path);
  }
  if (strcmp(command, "help") == 0 || strcmp(command, "--help") == 0) {
    print_usage();
    return 0;
  }

  fprintf(stderr, "loom: unknown command '%s'\n", command);
  print_usage();
  return 1;
}
