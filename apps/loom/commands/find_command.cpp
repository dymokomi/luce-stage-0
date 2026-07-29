#include "commands/find_command.h"

#include <stdio.h>

#include "commands/common.h"

namespace lucia {

const char *FindCommand::name() const {
    return "find";
}

Size FindCommand::argument_count() const {
    return 1;
}

const char *FindCommand::usage() const {
    return "find TEXT      list texels whose name contains TEXT";
}

CommandResult FindCommand::run(Store *store, const Strings &words) {
    Size matches = 0;
    for (Size i = 0; i < store->size(); ++i) {
        Texel texel;
        if (!store->at(i, &texel)) {
            return COMMAND_ERROR;
        }
        String found;
        if (!texel_name(texel, &found) || found.find(words[1]) == String::npos) {
            continue;
        }
        printf("%s %s\n", texel.id().format().c_str(), found.c_str());
        ++matches;
    }
    if (matches == 0) {
        printf("no matches\n");
    }
    return COMMAND_OK;
}

} // namespace lucia
