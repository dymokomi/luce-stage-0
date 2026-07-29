#include "commands/list_command.h"

#include <stdio.h>

#include "commands/common.h"

namespace lucia {

const char *ListCommand::name() const {
    return "list";
}

Size ListCommand::argument_count() const {
    return 0;
}

const char *ListCommand::usage() const {
    return "list           list every texel";
}

CommandResult ListCommand::run(Store *store, const Strings &) {
    for (Size i = 0; i < store->size(); ++i) {
        Texel texel;
        if (!store->at(i, &texel)) {
            return COMMAND_ERROR;
        }
        String     found;
        const bool named = texel_name(texel, &found);
        printf("%s %s\n", texel.id().format().c_str(), named ? found.c_str() : "-");
    }
    return COMMAND_OK;
}

} // namespace lucia
