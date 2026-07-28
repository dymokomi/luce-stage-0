#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "fabric/store.h"
#include "loom/spool.h"
#include "storage/file_volume.h"

using namespace lucia;

namespace {

enum { DEFAULT_PAGES = 64 };

class ConcatEvaluator : public Evaluator {
public:
  void evaluate(const Texel&, const ValueOutcomeMap& inputs,
                ValueOutcomeMap* outputs) override
  {
    ValueOutcomeMap::const_iterator left  = inputs.find("left");
    ValueOutcomeMap::const_iterator right = inputs.find("right");
    if (left == inputs.end() || right == inputs.end() ||
        left->second.status() != VALUE_AVAILABLE ||
        right->second.status() != VALUE_AVAILABLE) {
      (*outputs)["value"] = ValueOutcome::unavailable();
      return;
    }
    (*outputs)["value"] = ValueOutcome::available(
        Value(left->second.value().text() + right->second.value().text()));
  }
};

void usage()
{
  fprintf(stderr,
          "usage:\n"
          "  loom init [--image PATH] [--pages N]\n"
          "  loom status [--image PATH]\n"
          "  loom list [--image PATH]\n"
          "  loom show ID [--image PATH]\n"
          "  loom source TEXT [--image PATH]\n"
          "  loom concat LEFT_ID RIGHT_ID [--image PATH]\n"
          "  loom connect TARGET INPUT SOURCE OUTPUT [--image PATH]\n"
          "  loom pull ID OUTPUT [--image PATH]\n"
          "  loom demo [--image PATH]\n");
}

bool parse_id(const char* text, TexelId* id)
{
  return id != 0 && id->parse(text) && !id->is_unset();
}

bool open_store(const char* path, FileVolume* volume, Store* store)
{
  if (!volume->open(path)) {
    fprintf(stderr, "loom: cannot open image %s\n", path);
    return false;
  }
  if (!store->open(volume)) {
    fprintf(stderr, "loom: cannot open Fabric %s\n", path);
    return false;
  }
  return true;
}

Texel make_source(const char* text)
{
  TexelId id;
  id.generate();
  Texel texel(id);
  OutputPort output("value", VALUE_TEXT);
  output.set_source(Value(text));
  texel.put_output(output);
  return texel;
}

bool put_texel(Store* store, const Texel& texel)
{
  Transaction transaction;
  return store->begin(&transaction) &&
         transaction.put(texel) &&
         transaction.commit();
}

int command_init(const char* path, U64 pages)
{
  FileVolume volume;
  if (!volume.create(path, pages)) {
    fprintf(stderr, "loom: cannot create image %s\n", path);
    return 1;
  }
  Store store;
  if (!store.create(&volume)) {
    fprintf(stderr, "loom: cannot initialize Fabric\n");
    return 1;
  }
  printf("created %s generation=%llu\n", path,
         (unsigned long long)store.generation());
  return 0;
}

int command_status(const char* path)
{
  FileVolume volume;
  Store store;
  if (!open_store(path, &volume, &store)) {
    return 1;
  }
  printf("image: %s\n", path);
  printf("generation: %llu\n", (unsigned long long)store.generation());
  printf("texels: %zu\n", store.size());
  return 0;
}

int command_list(const char* path)
{
  FileVolume volume;
  Store store;
  if (!open_store(path, &volume, &store)) {
    return 1;
  }
  for (Size i = 0; i < store.size(); ++i) {
    Texel texel;
    if (!store.at(i, &texel)) {
      return 1;
    }
    printf("%s inputs=%zu outputs=%zu evaluator=%s\n",
           texel.id().format().c_str(), texel.input_size(),
           texel.output_size(),
           texel.evaluator().empty() ? "-" : texel.evaluator().c_str());
  }
  return 0;
}

int command_show(const char* path, const TexelId& id)
{
  FileVolume volume;
  Store store;
  if (!open_store(path, &volume, &store)) {
    return 1;
  }
  Texel texel;
  if (!store.get(id, &texel)) {
    fprintf(stderr, "loom: texel not found\n");
    return 1;
  }
  printf("id: %s\n", texel.id().format().c_str());
  printf("revision: %llu\n", (unsigned long long)texel.revision());
  printf("evaluator: %s\n",
         texel.evaluator().empty() ? "-" : texel.evaluator().c_str());
  for (Size i = 0; i < texel.input_size(); ++i) {
    InputPort input;
    texel.input_at(i, &input);
    printf("input %s type=%d bound=%s\n", input.name().c_str(),
           (int)input.type(), input.has_binding() ? "yes" : "no");
  }
  for (Size i = 0; i < texel.output_size(); ++i) {
    OutputPort output;
    texel.output_at(i, &output);
    printf("output %s type=%d source=%s revision=%llu\n",
           output.name().c_str(), (int)output.type(),
           output.has_source() ? "yes" : "no",
           (unsigned long long)output.revision());
  }
  return 0;
}

int command_source(const char* path, const char* text)
{
  FileVolume volume;
  Store store;
  if (!open_store(path, &volume, &store)) {
    return 1;
  }
  Texel texel = make_source(text);
  if (!put_texel(&store, texel)) {
    fprintf(stderr, "loom: source commit failed\n");
    return 1;
  }
  printf("%s\n", texel.id().format().c_str());
  return 0;
}

int command_concat(const char* path, const TexelId& left,
                   const TexelId& right)
{
  FileVolume volume;
  Store store;
  if (!open_store(path, &volume, &store)) {
    return 1;
  }

  TexelId id;
  id.generate();
  Texel texel(id);
  texel.set_evaluator("concat");
  texel.put_input(InputPort("left", VALUE_TEXT));
  texel.put_input(InputPort("right", VALUE_TEXT));
  texel.put_output(OutputPort("value", VALUE_TEXT));

  Transaction transaction;
  if (!store.begin(&transaction) ||
      !transaction.put(texel) ||
      !transaction.connect(id, "left", left, "value") ||
      !transaction.connect(id, "right", right, "value") ||
      !transaction.commit()) {
    fprintf(stderr, "loom: concat commit failed\n");
    return 1;
  }
  printf("%s\n", id.format().c_str());
  return 0;
}

int command_connect(const char* path, const TexelId& target,
                    const char* input, const TexelId& source,
                    const char* output)
{
  FileVolume volume;
  Store store;
  if (!open_store(path, &volume, &store)) {
    return 1;
  }
  Transaction transaction;
  if (!store.begin(&transaction) ||
      !transaction.connect(target, input, source, output) ||
      !transaction.commit()) {
    fprintf(stderr, "loom: connect failed\n");
    return 1;
  }
  return 0;
}

int command_pull(const char* path, const TexelId& id, const char* output)
{
  FileVolume volume;
  Store store;
  if (!open_store(path, &volume, &store)) {
    return 1;
  }

  ConcatEvaluator concat;
  EvaluatorRegistry registry;
  registry.put("concat", &concat);
  Spool spool(&store, &registry);

  ValueOutcome outcome;
  if (!spool.demand(id, output, &outcome)) {
    return 1;
  }
  if (outcome.status() == VALUE_ERROR) {
    fprintf(stderr, "loom: %s\n", outcome.message().c_str());
    return 1;
  }
  if (outcome.status() == VALUE_UNAVAILABLE) {
    printf("unavailable\n");
    return 0;
  }
  if (outcome.value().type() == VALUE_TEXT) {
    printf("%s\n", outcome.value().text().c_str());
  } else {
    printf("available type=%d\n", (int)outcome.value().type());
  }
  return 0;
}

int command_demo(const char* path)
{
  if (command_init(path, DEFAULT_PAGES) != 0) {
    return 1;
  }

  FileVolume volume;
  Store store;
  if (!open_store(path, &volume, &store)) {
    return 1;
  }

  Texel left = make_source("hello ");
  Texel right = make_source("loom");
  TexelId joined_id;
  joined_id.generate();
  Texel joined(joined_id);
  joined.set_evaluator("concat");
  joined.put_input(InputPort("left", VALUE_TEXT));
  joined.put_input(InputPort("right", VALUE_TEXT));
  joined.put_output(OutputPort("value", VALUE_TEXT));

  Transaction transaction;
  if (!store.begin(&transaction) ||
      !transaction.put(left) ||
      !transaction.put(right) ||
      !transaction.put(joined) ||
      !transaction.connect(joined.id(), "left", left.id(), "value") ||
      !transaction.connect(joined.id(), "right", right.id(), "value") ||
      !transaction.commit()) {
    fprintf(stderr, "loom: demo commit failed\n");
    return 1;
  }

  Store reopened;
  FileVolume reopened_volume;
  if (!open_store(path, &reopened_volume, &reopened)) {
    return 1;
  }
  ConcatEvaluator concat;
  EvaluatorRegistry registry;
  registry.put("concat", &concat);
  Spool spool(&reopened, &registry);
  ValueOutcome outcome;
  if (!spool.demand(joined.id(), "value", &outcome) ||
      outcome.status() != VALUE_AVAILABLE ||
      outcome.value().text() != "hello loom") {
    fprintf(stderr, "loom: demo demand failed\n");
    return 1;
  }
  printf("demo ok: %s\n", outcome.value().text().c_str());
  return 0;
}

}  // namespace

int main(int argc, char** argv)
{
  if (argc < 2) {
    usage();
    return 1;
  }

  const char* command = argv[1];
  const char* image = "loom.img";
  U64 pages = DEFAULT_PAGES;
  const char* positional[4] = { 0, 0, 0, 0 };
  int positional_count = 0;

  for (int i = 2; i < argc; ++i) {
    if (strcmp(argv[i], "--image") == 0 && i + 1 < argc) {
      image = argv[++i];
    } else if (strcmp(argv[i], "--pages") == 0 && i + 1 < argc) {
      pages = (U64)strtoull(argv[++i], 0, 10);
    } else if (positional_count < 4) {
      positional[positional_count++] = argv[i];
    } else {
      usage();
      return 1;
    }
  }

  if (strcmp(command, "init") == 0 && positional_count == 0) {
    return command_init(image, pages);
  }
  if (strcmp(command, "status") == 0 && positional_count == 0) {
    return command_status(image);
  }
  if (strcmp(command, "list") == 0 && positional_count == 0) {
    return command_list(image);
  }
  if (strcmp(command, "source") == 0 && positional_count == 1) {
    return command_source(image, positional[0]);
  }
  if (strcmp(command, "demo") == 0 && positional_count == 0) {
    return command_demo(image);
  }

  TexelId first;
  TexelId second;
  if (strcmp(command, "show") == 0 && positional_count == 1 &&
      parse_id(positional[0], &first)) {
    return command_show(image, first);
  }
  if (strcmp(command, "pull") == 0 && positional_count == 2 &&
      parse_id(positional[0], &first)) {
    return command_pull(image, first, positional[1]);
  }
  if (strcmp(command, "concat") == 0 && positional_count == 2 &&
      parse_id(positional[0], &first) &&
      parse_id(positional[1], &second)) {
    return command_concat(image, first, second);
  }
  if (strcmp(command, "connect") == 0 && positional_count == 4 &&
      parse_id(positional[0], &first) &&
      parse_id(positional[2], &second)) {
    return command_connect(image, first, positional[1], second,
                           positional[3]);
  }

  usage();
  return 1;
}
