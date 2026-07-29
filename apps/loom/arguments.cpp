#include "arguments.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

namespace lucia {

bool parse_arguments(int argc, char **argv, Arguments *arguments) {
  if (arguments == 0 || argc < 2) {
    return false;
  }

  arguments->command          = argv[1];
  arguments->image            = "loom.img";
  arguments->pages            = DEFAULT_PAGES;
  arguments->positional_count = 0;
  for (int i = 0; i < 4; ++i) {
    arguments->positional[i] = 0;
  }

  for (int i = 2; i < argc; ++i) {
    if (strcmp(argv[i], "--image") == 0 && i + 1 < argc) {
      arguments->image = argv[++i];
    } else if (strcmp(argv[i], "--pages") == 0 && i + 1 < argc) {
      arguments->pages = (U64)strtoull(argv[++i], 0, 10);
    } else if (arguments->positional_count < 4) {
      arguments->positional[arguments->positional_count++] = argv[i];
    } else {
      return false;
    }
  }
  return true;
}

void print_usage() {
  fprintf(stderr, "usage:\n"
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

} // namespace lucia
