#include "commands/new_command.h"

#include <stdio.h>

#include "commands/common.h"

namespace lucia {

const char *NewCommand::name() const {
    return "new";
}

Size NewCommand::argument_count() const {
    return 1;
}

const char *NewCommand::usage() const {
    return "new NAME       create a texel and print its id";
}

CommandResult NewCommand::run(Store *store, const Strings &words) {
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

} // namespace lucia
