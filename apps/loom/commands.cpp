#include "commands.h"

#include <stdio.h>
#include <string.h>

#include "evaluators.h"
#include "image.h"
#include "loom/evaluation/spool.h"

namespace lucia {
namespace {

// ---------------------------------------------------------------------------
// Shared helpers
// ---------------------------------------------------------------------------

const char *image_path(const CommandLine &line) {
  return line.option("--image", DEFAULT_IMAGE);
}

bool parse_id(const char *text, TexelId *id) {
  if (!id->parse(text) || id->is_unset()) {
    fprintf(stderr, "loom: invalid texel id %s\n", text);
    return false;
  }
  return true;
}

// Build a source Texel offering constant text on "value".
Texel make_source(const char *text) {
  TexelId id;
  id.generate();
  Texel      texel(id);
  OutputPort output("value", VALUE_TEXT);
  output.set_source(Value(text));
  texel.put_output(output);
  return texel;
}

bool put_texel(Store *store, const Texel &texel) {
  Transaction transaction;
  return store->begin(&transaction) && transaction.put(texel) && transaction.commit();
}

// Create a concat Texel wired to two upstream "value" outputs, in one commit.
bool put_concat(Store *store, const TexelId &left, const TexelId &right, TexelId *id) {
  id->generate();
  Texel texel(*id);
  texel.set_evaluator("concat");
  texel.put_input(InputPort("left", VALUE_TEXT));
  texel.put_input(InputPort("right", VALUE_TEXT));
  texel.put_output(OutputPort("value", VALUE_TEXT));

  Transaction transaction;
  return store->begin(&transaction) && transaction.put(texel) &&
         transaction.connect(*id, "left", left, "value") &&
         transaction.connect(*id, "right", right, "value") && transaction.commit();
}

// ---------------------------------------------------------------------------
// Commands
// ---------------------------------------------------------------------------

int run_init(const CommandLine &line) {
  Image image;
  if (!image.create(image_path(line), line.option_u64("--pages", DEFAULT_PAGES))) {
    return 1;
  }
  printf("created %s generation=%llu\n", image_path(line),
         (unsigned long long)image.store()->generation());
  return 0;
}

int run_status(const CommandLine &line) {
  Image image;
  if (!image.open(image_path(line))) {
    return 1;
  }
  printf("image: %s\n", image_path(line));
  printf("generation: %llu\n", (unsigned long long)image.store()->generation());
  printf("texels: %zu\n", image.store()->size());
  return 0;
}

int run_list(const CommandLine &line) {
  Image image;
  if (!image.open(image_path(line))) {
    return 1;
  }
  const Store *store = image.store();
  for (Size i = 0; i < store->size(); ++i) {
    Texel texel;
    if (!store->at(i, &texel)) {
      return 1;
    }
    printf("%s inputs=%zu outputs=%zu evaluator=%s\n", texel.id().format().c_str(),
           texel.input_size(), texel.output_size(),
           texel.evaluator().empty() ? "-" : texel.evaluator().c_str());
  }
  return 0;
}

int run_show(const CommandLine &line) {
  TexelId id;
  if (!parse_id(line.positional(0), &id)) {
    return 1;
  }
  Image image;
  if (!image.open(image_path(line))) {
    return 1;
  }
  Texel texel;
  if (!image.store()->get(id, &texel)) {
    fprintf(stderr, "loom: texel not found\n");
    return 1;
  }
  printf("id: %s\n", texel.id().format().c_str());
  printf("revision: %llu\n", (unsigned long long)texel.revision());
  printf("evaluator: %s\n", texel.evaluator().empty() ? "-" : texel.evaluator().c_str());
  for (Size i = 0; i < texel.input_size(); ++i) {
    InputPort input;
    texel.input_at(i, &input);
    printf("input %s type=%d bound=%s\n", input.name().c_str(), (int)input.type(),
           input.has_binding() ? "yes" : "no");
  }
  for (Size i = 0; i < texel.output_size(); ++i) {
    OutputPort output;
    texel.output_at(i, &output);
    printf("output %s type=%d source=%s revision=%llu\n", output.name().c_str(),
           (int)output.type(), output.has_source() ? "yes" : "no",
           (unsigned long long)output.revision());
  }
  return 0;
}

int run_source(const CommandLine &line) {
  Image image;
  if (!image.open(image_path(line))) {
    return 1;
  }
  Texel texel = make_source(line.positional(0));
  if (!put_texel(image.store(), texel)) {
    fprintf(stderr, "loom: source commit failed\n");
    return 1;
  }
  printf("%s\n", texel.id().format().c_str());
  return 0;
}

int run_concat(const CommandLine &line) {
  TexelId left;
  TexelId right;
  if (!parse_id(line.positional(0), &left) || !parse_id(line.positional(1), &right)) {
    return 1;
  }
  Image image;
  if (!image.open(image_path(line))) {
    return 1;
  }
  TexelId id;
  if (!put_concat(image.store(), left, right, &id)) {
    fprintf(stderr, "loom: concat commit failed\n");
    return 1;
  }
  printf("%s\n", id.format().c_str());
  return 0;
}

int run_connect(const CommandLine &line) {
  TexelId target;
  TexelId source;
  if (!parse_id(line.positional(0), &target) || !parse_id(line.positional(2), &source)) {
    return 1;
  }
  Image image;
  if (!image.open(image_path(line))) {
    return 1;
  }
  Transaction transaction;
  if (!image.store()->begin(&transaction) ||
      !transaction.connect(target, line.positional(1), source, line.positional(3)) ||
      !transaction.commit()) {
    fprintf(stderr, "loom: connect failed\n");
    return 1;
  }
  return 0;
}

int run_pull(const CommandLine &line) {
  TexelId id;
  if (!parse_id(line.positional(0), &id)) {
    return 1;
  }
  Image image;
  if (!image.open(image_path(line))) {
    return 1;
  }
  EvaluatorSet evaluators;
  Spool        spool(image.store(), evaluators.registry());
  ValueOutcome outcome;
  if (!spool.demand(id, line.positional(1), &outcome)) {
    fprintf(stderr, "loom: demand failed\n");
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

int run_demo(const CommandLine &line) {
  const char *path = image_path(line);

  TexelId joined;
  {
    Image image;
    if (!image.create(path, DEFAULT_PAGES)) {
      return 1;
    }
    Texel left  = make_source("hello ");
    Texel right = make_source("loom");
    if (!put_texel(image.store(), left) || !put_texel(image.store(), right) ||
        !put_concat(image.store(), left.id(), right.id(), &joined)) {
      fprintf(stderr, "loom: demo commit failed\n");
      return 1;
    }
  }

  // Reopen from disk to prove the material survives restart.
  Image image;
  if (!image.open(path)) {
    return 1;
  }
  EvaluatorSet evaluators;
  Spool        spool(image.store(), evaluators.registry());
  ValueOutcome outcome;
  if (!spool.demand(joined, "value", &outcome) || outcome.status() != VALUE_AVAILABLE ||
      outcome.value().text() != "hello loom") {
    fprintf(stderr, "loom: demo demand failed\n");
    return 1;
  }
  printf("demo ok: %s\n", outcome.value().text().c_str());
  return 0;
}

// ---------------------------------------------------------------------------
// Command table
// ---------------------------------------------------------------------------
//
// One row per subcommand: name, required positional count, usage line, and
// the function that runs it.  Dispatch and usage both come from this table.
//
typedef int (*CommandRun)(const CommandLine &line);

struct Command {
  const char *name;
  Size        positional_count;
  const char *usage;
  CommandRun  run;
};

const Command COMMANDS[] = {
    {"init", 0, "loom init [--image PATH] [--pages N]", run_init},
    {"status", 0, "loom status [--image PATH]", run_status},
    {"list", 0, "loom list [--image PATH]", run_list},
    {"show", 1, "loom show ID [--image PATH]", run_show},
    {"source", 1, "loom source TEXT [--image PATH]", run_source},
    {"concat", 2, "loom concat LEFT_ID RIGHT_ID [--image PATH]", run_concat},
    {"connect", 4, "loom connect TARGET INPUT SOURCE OUTPUT [--image PATH]", run_connect},
    {"pull", 2, "loom pull ID OUTPUT [--image PATH]", run_pull},
    {"demo", 0, "loom demo [--image PATH]", run_demo},
};

enum { COMMAND_COUNT = sizeof(COMMANDS) / sizeof(COMMANDS[0]) };

} // namespace

int run_command(const CommandLine &line) {
  for (Size i = 0; i < COMMAND_COUNT; ++i) {
    const Command &command = COMMANDS[i];
    if (strcmp(line.command(), command.name) != 0) {
      continue;
    }
    if (line.positional_size() != command.positional_count) {
      fprintf(stderr, "usage: %s\n", command.usage);
      return 1;
    }
    return command.run(line);
  }
  print_usage();
  return 1;
}

void print_usage() {
  fprintf(stderr, "usage:\n");
  for (Size i = 0; i < COMMAND_COUNT; ++i) {
    fprintf(stderr, "  %s\n", COMMANDS[i].usage);
  }
}

} // namespace lucia
