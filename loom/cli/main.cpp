#include "loom/cli/arguments.h"
#include "loom/cli/commands.h"

int main(int argc, char **argv) {
  lucia::Arguments arguments;
  if (!lucia::parse_arguments(argc, argv, &arguments)) {
    lucia::print_usage();
    return 1;
  }
  return lucia::run_command(arguments);
}
