#include "terminal.h"

#include <stdio.h>
#include <unistd.h>

#include "boundary.h"
#include "command_line.h"
#include "commands/common.h"

namespace lucia {

enum { LINE_SIZE = 1024 };

Terminal::Terminal(Store *store) {
    session.store      = store;
    session.evaluators = evaluators.registry();
}

// The prompt names the selection: "loom>", or "loom alpha>" while the texel
// named alpha is selected (its short id when it has no name).
static String prompt_text(const Session &session) {
    String prompt = "loom";
    Texel  texel;
    if (session.has_selection() && session.store->get(session.selected, &texel)) {
        String name;
        prompt += " ";
        prompt += texel_name(texel, &name) ? name : session.selected.format().substr(0, 8);
    }
    return prompt + "> ";
}

int Terminal::run() {
    const bool interactive = isatty(0) != 0;
    char       line[LINE_SIZE];

    if (!ensure_boundary(session.store)) {
        fprintf(stderr, "loom: cannot create boundary texels\n");
    }

    for (;;) {
        if (interactive) {
            printf("%s", prompt_text(session).c_str());
            fflush(stdout);
        }
        if (fgets(line, LINE_SIZE, stdin) == 0) {
            if (interactive) {
                printf("\n");
            }
            return 0;
        }

        // The keyboard boundary observes every interaction before the
        // command runs, so keyboard.line always holds the newest line.
        String typed(line);
        while (!typed.empty() &&
               (typed[typed.size() - 1] == '\n' || typed[typed.size() - 1] == '\r')) {
            typed.erase(typed.size() - 1);
        }
        observe_keyboard(session.store, typed);

        Strings words;
        if (!split_words(line, &words)) {
            fprintf(stderr, "loom: unbalanced quotes\n");
            continue;
        }
        if (words.empty()) {
            continue;
        }

        const CommandResult result = commands.run(&session, words);
        if (result == COMMAND_EXIT) {
            return 0;
        }
        if (result == COMMAND_UNKNOWN) {
            fprintf(stderr, "loom: unknown command %s (try help)\n", words[0].c_str());
        }
    }
}

} // namespace lucia
