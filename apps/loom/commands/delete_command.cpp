#include "commands/delete_command.h"

#include <stdio.h>

#include "commands/common.h"

namespace lucia {

const char *DeleteCommand::name() const {
    return "delete";
}

Size DeleteCommand::argument_count() const {
    return 1;
}

const char *DeleteCommand::usage() const {
    return "delete ID      remove a texel";
}

CommandResult DeleteCommand::run(Store *store, const Strings &words) {
    TexelId id;
    if (!parse_id(words[1], &id)) {
        return COMMAND_ERROR;
    }
    if (!store->has(id)) {
        fprintf(stderr, "loom: texel not found\n");
        return COMMAND_ERROR;
    }
    Transaction transaction;
    if (!store->begin(&transaction) || !transaction.remove(id) || !transaction.commit()) {
        fprintf(stderr, "loom: delete failed (texel is still connected)\n");
        return COMMAND_ERROR;
    }
    return COMMAND_OK;
}

} // namespace lucia
