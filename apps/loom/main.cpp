#include "command_line.h"
#include "commands.h"

int main(int argc, char **argv) {
  lucia::CommandLine line;
  if (!line.parse(argc, argv)) {
    lucia::print_usage();
    return 1;
  }
  return lucia::run_command(line);
}
