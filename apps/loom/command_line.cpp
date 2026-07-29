#include "command_line.h"

#include <stdlib.h>
#include <string.h>

namespace lucia {

CommandLine::CommandLine() : command_word(0) {}

bool CommandLine::parse(int argc, char **argv) {
  if (argv == 0 || argc < 2) {
    return false;
  }

  command_word = argv[1];
  options.clear();
  positionals.clear();

  for (int i = 2; i < argc; ++i) {
    if (strncmp(argv[i], "--", 2) == 0) {
      if (i + 1 >= argc) {
        return false;
      }
      options[argv[i]] = argv[i + 1];
      ++i;
    } else {
      positionals.push_back(argv[i]);
    }
  }
  return true;
}

const char *CommandLine::command() const {
  return command_word;
}

const char *CommandLine::option(const char *name, const char *fallback) const {
  OptionTable::const_iterator found = options.find(name);
  return found == options.end() ? fallback : found->second;
}

U64 CommandLine::option_u64(const char *name, U64 fallback) const {
  OptionTable::const_iterator found = options.find(name);
  return found == options.end() ? fallback : (U64)strtoull(found->second, 0, 10);
}

Size CommandLine::positional_size() const {
  return positionals.size();
}

const char *CommandLine::positional(Size index) const {
  return index < positionals.size() ? positionals[index] : 0;
}

} // namespace lucia
