#pragma once

#include <stdio.h>

#include "command.h"
#include "commands/common.h"

namespace lucia {

// ---------------------------------------------------------------------------
// NewCommand
// ---------------------------------------------------------------------------
//
// new NAME — create a texel named NAME and print its id.
//
class NewCommand : public Command {
public:
    const char *name() const override {
        return "new";
    }

    Size argument_count() const override {
        return 1;
    }

    const char *usage() const override {
        return "new NAME       create a texel and print its id";
    }

    CommandResult run(Store *store, const Strings &words) override {
        TexelId id;
        id.generate();
        Texel texel(id);
        set_name(&texel, words[1]);
        if (!commit_put(store, texel)) {
            fprintf(stderr, "loom: new commit failed\n");
            return COMMAND_ERROR;
        }
        printf("%s\n", id.format().c_str());
        return COMMAND_OK;
    }
};

} // namespace lucia
