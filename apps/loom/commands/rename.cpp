#include "commands/rename.h"

#include <stdio.h>

#include "commands/common.h"

namespace lucia {

const char *RenameCommand::name() const {
    return "rename";
}

Size RenameCommand::argument_count() const {
    return 2;
}

const char *RenameCommand::usage() const {
    return "rename ID NAME give a texel a new name";
}

CommandResult RenameCommand::run(Store *store, const Strings &words) {
    TexelId id;
    if (!parse_id(words[1], &id)) {
        return COMMAND_ERROR;
    }
    Texel texel;
    if (!store->get(id, &texel)) {
        fprintf(stderr, "loom: texel not found\n");
        return COMMAND_ERROR;
    }
    set_name(&texel, words[2]);
    if (!commit_put(store, texel)) {
        fprintf(stderr, "loom: rename commit failed\n");
        return COMMAND_ERROR;
    }
    return COMMAND_OK;
}

} // namespace lucia
