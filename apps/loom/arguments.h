#pragma once

#include "base/types.h"

namespace lucia {

enum { DEFAULT_PAGES = 64 };

struct Arguments {
  const char *command;
  const char *image;
  U64         pages;
  const char *positional[4];
  int         positional_count;
};

bool parse_arguments(int argc, char **argv, Arguments *arguments);
void print_usage();

} // namespace lucia
