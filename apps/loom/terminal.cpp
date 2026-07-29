#include "terminal.h"

#include <stdio.h>
#include <unistd.h>

#include "boundary.h"
#include "command_line.h"
#include "commands/common.h"

namespace lucia {

enum { LINE_SIZE = 1024 };

Terminal::Terminal(loom_store *store) : spool(0), index(0), seen(0) {
    session.store = store;
    loom_spool_new(store, evaluators.get(), &spool);
    loom_index_new(&index);
    session.spool = spool;
}

Terminal::~Terminal() {
    loom_spool_free(spool);
    loom_index_free(index);
}

// The prompt names the selection: "loom>", or "loom alpha>" while the
// texel named alpha is selected (its short id when it has no name).
static String prompt_text(const Session &session) {
    String prompt = "loom";
    if (session.has_selection() && loom_store_has(session.store, session.selected.bytes)) {
        prompt += " " + texel_label(session.store, session.selected);
    }
    return prompt + "> ";
}

// Reconcile the disposable machinery with whatever the last command (or
// keyboard observation) changed, then re-demand only the dirty watches.
void Terminal::reconcile() {
    const U64 current = loom_store_generation(session.store);
    if (current == seen) {
        return;
    }

    IdListBox   changed;
    IdListBox   dirty;
    bool        full   = false;
    loom_status status = loom_store_changes_since(session.store, seen, changed.out());
    if (status == LOOM_OK) {
        loom_index_apply(index, session.store, changed.get());
        loom_index_downstream(index, changed.get(), dirty.out());
        loom_spool_advance(spool, seen, current, dirty.get());
    } else {
        loom_index_build(index, session.store);
        loom_spool_clear(spool);
        full = true;
    }
    seen = current;

    for (WatchList::iterator watch = session.watches.begin();
         watch != session.watches.end(); ++watch) {
        if (!full && !dirty.contains(watch->texel)) {
            continue;
        }
        Outcome outcome;
        if (loom_spool_demand(spool, watch->texel.bytes, watch->output.c_str(),
                              &outcome.raw) != LOOM_OK) {
            continue;
        }
        const String rendered = outcome_text(outcome.raw);
        if (rendered == watch->last) {
            continue;
        }
        watch->last = rendered;
        print_outcome(session.store, watch->texel, watch->output, outcome.raw);
    }
}

int Terminal::run() {
    const bool interactive = isatty(0) != 0;
    char       line[LINE_SIZE];

    if (spool == 0 || index == 0) {
        fprintf(stderr, "loom: cannot start the terminal\n");
        return 1;
    }
    if (!ensure_boundary(session.store)) {
        fprintf(stderr, "loom: cannot create boundary texels\n");
    }
    loom_index_build(index, session.store);
    seen = loom_store_generation(session.store);

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
        reconcile();
    }
}

} // namespace lucia
