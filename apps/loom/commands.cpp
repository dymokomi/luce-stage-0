#include "commands.h"

#include <stdio.h>

namespace lucia {
namespace {

// A texel's name is ordinary Fabric material: a text value offered on the
// "name" Output Port.  Identity never depends on it.
const char NAME_PORT[] = "name";

// ---------------------------------------------------------------------------
// Shared helpers
// ---------------------------------------------------------------------------

bool parse_id(const String &text, TexelId *id) {
  if (!id->parse(text.c_str()) || id->is_unset()) {
    fprintf(stderr, "loom: invalid texel id %s\n", text.c_str());
    return false;
  }
  return true;
}

bool texel_name(const Texel &texel, String *name) {
  OutputPort port;
  if (!texel.get_output(NAME_PORT, &port) || !port.has_source() ||
      port.source().type() != VALUE_TEXT) {
    return false;
  }
  *name = port.source().text();
  return true;
}

bool commit_put(Store *store, const Texel &texel) {
  Transaction transaction;
  return store->begin(&transaction) && transaction.put(texel) && transaction.commit();
}

// ---------------------------------------------------------------------------
// Commands
// ---------------------------------------------------------------------------

CommandResult run_new(Store *store, const Strings &words) {
  TexelId id;
  id.generate();
  Texel      texel(id);
  OutputPort name(NAME_PORT, VALUE_TEXT);
  name.set_source(Value(words[1]));
  texel.put_output(name);
  if (!commit_put(store, texel)) {
    fprintf(stderr, "loom: new commit failed\n");
    return COMMAND_ERROR;
  }
  printf("%s\n", id.format().c_str());
  return COMMAND_OK;
}

CommandResult run_rename(Store *store, const Strings &words) {
  TexelId id;
  if (!parse_id(words[1], &id)) {
    return COMMAND_ERROR;
  }
  Texel texel;
  if (!store->get(id, &texel)) {
    fprintf(stderr, "loom: texel not found\n");
    return COMMAND_ERROR;
  }
  OutputPort name;
  if (!texel.get_output(NAME_PORT, &name)) {
    name = OutputPort(NAME_PORT, VALUE_TEXT);
  }
  name.set_source(Value(words[2]));
  texel.put_output(name);
  if (!commit_put(store, texel)) {
    fprintf(stderr, "loom: rename commit failed\n");
    return COMMAND_ERROR;
  }
  return COMMAND_OK;
}

CommandResult run_find(Store *store, const Strings &words) {
  Size matches = 0;
  for (Size i = 0; i < store->size(); ++i) {
    Texel texel;
    if (!store->at(i, &texel)) {
      return COMMAND_ERROR;
    }
    String name;
    if (!texel_name(texel, &name) || name.find(words[1]) == String::npos) {
      continue;
    }
    printf("%s %s\n", texel.id().format().c_str(), name.c_str());
    ++matches;
  }
  if (matches == 0) {
    printf("no matches\n");
  }
  return COMMAND_OK;
}

CommandResult run_delete(Store *store, const Strings &words) {
  TexelId id;
  if (!parse_id(words[1], &id)) {
    return COMMAND_ERROR;
  }
  if (!store->has(id)) {
    fprintf(stderr, "loom: texel not found\n");
    return COMMAND_ERROR;
  }
  Transaction transaction;
  if (!store->begin(&transaction) || !transaction.remove(id) || !transaction.commit()) {
    fprintf(stderr, "loom: delete failed (texel is still connected)\n");
    return COMMAND_ERROR;
  }
  return COMMAND_OK;
}

CommandResult run_list(Store *store, const Strings &) {
  for (Size i = 0; i < store->size(); ++i) {
    Texel texel;
    if (!store->at(i, &texel)) {
      return COMMAND_ERROR;
    }
    String     name;
    const bool named = texel_name(texel, &name);
    printf("%s %s\n", texel.id().format().c_str(), named ? name.c_str() : "-");
  }
  return COMMAND_OK;
}

CommandResult run_help(Store *, const Strings &) {
  print_commands();
  return COMMAND_OK;
}

CommandResult run_exit(Store *, const Strings &) {
  return COMMAND_EXIT;
}

// ---------------------------------------------------------------------------
// Command table
// ---------------------------------------------------------------------------
//
// One row per terminal command: name, required argument count, usage line,
// and the function that runs it.  Dispatch and help both come from here.
//
struct Command {
  const char *name;
  Size        argument_count;
  const char *usage;
  CommandResult (*run)(Store *store, const Strings &words);
};

const Command COMMANDS[] = {
    {"new", 1, "new NAME       create a texel and print its id", run_new},
    {"rename", 2, "rename ID NAME give a texel a new name", run_rename},
    {"find", 1, "find TEXT      list texels whose name contains TEXT", run_find},
    {"delete", 1, "delete ID      remove a texel", run_delete},
    {"list", 0, "list           list every texel", run_list},
    {"help", 0, "help           show this list", run_help},
    {"exit", 0, "exit           leave the terminal", run_exit},
};

enum { COMMAND_COUNT = sizeof(COMMANDS) / sizeof(COMMANDS[0]) };

} // namespace

CommandResult run_command(Store *store, const Strings &words) {
  for (Size i = 0; i < COMMAND_COUNT; ++i) {
    const Command &command = COMMANDS[i];
    if (words[0] != command.name) {
      continue;
    }
    if (words.size() - 1 != command.argument_count) {
      fprintf(stderr, "usage: %s\n", command.usage);
      return COMMAND_ERROR;
    }
    return command.run(store, words);
  }
  return COMMAND_UNKNOWN;
}

void print_commands() {
  printf("commands:\n");
  for (Size i = 0; i < COMMAND_COUNT; ++i) {
    printf("  %s\n", COMMANDS[i].usage);
  }
}

} // namespace lucia
