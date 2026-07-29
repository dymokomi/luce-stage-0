#include <stdio.h>
#include <string.h>

#include "command_line.h"
#include "image.h"
#include "terminal.h"

namespace lucia {

static void print_usage() {
  fprintf(stderr, "usage:\n"
                  "  loom create IMAGE [--pages N]\n"
                  "  loom open IMAGE\n");
}

static int run_create(const CommandLine &line) {
  Image image;
  if (!image.create(line.positional(0), line.option_u64("--pages", DEFAULT_PAGES))) {
    return 1;
  }
  printf("created %s\n", line.positional(0));
  return 0;
}

static int run_open(const CommandLine &line) {
  Image image;
  if (!image.open(line.positional(0))) {
    return 1;
  }
  Terminal terminal(image.store());
  return terminal.run();
}

} // namespace lucia

int main(int argc, char **argv) {
  lucia::CommandLine line;
  if (!line.parse(argc, argv) || line.positional_size() != 1) {
    lucia::print_usage();
    return 1;
  }
  if (strcmp(line.command(), "create") == 0) {
    return lucia::run_create(line);
  }
  if (strcmp(line.command(), "open") == 0) {
    return lucia::run_open(line);
  }
  lucia::print_usage();
  return 1;
}
