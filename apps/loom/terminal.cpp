#include "terminal.h"

#include <stdio.h>
#include <unistd.h>

#include "command_line.h"

namespace lucia {

enum { LINE_SIZE = 1024 };

Terminal::Terminal(Store *store) : fabric(store) {}

int Terminal::run() {
  const bool interactive = isatty(0) != 0;
  char       line[LINE_SIZE];

  for (;;) {
    if (interactive) {
      printf("loom> ");
      fflush(stdout);
    }
    if (fgets(line, LINE_SIZE, stdin) == 0) {
      if (interactive) {
        printf("\n");
      }
      return 0;
    }

    Strings words;
    if (!split_words(line, &words)) {
      fprintf(stderr, "loom: unbalanced quotes\n");
      continue;
    }
    if (words.empty()) {
      continue;
    }

    const CommandResult result = run_command(fabric, words);
    if (result == COMMAND_EXIT) {
      return 0;
    }
    if (result == COMMAND_UNKNOWN) {
      fprintf(stderr, "loom: unknown command %s (try help)\n", words[0].c_str());
    }
  }
}

} // namespace lucia
