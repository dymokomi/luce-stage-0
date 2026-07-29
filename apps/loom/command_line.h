#pragma once

#include "base/types.h"

#include <map>
#include <vector>

namespace lucia {

typedef std::map<String, const char *> OptionTable;
typedef std::vector<const char *>      ArgumentList;

// ---------------------------------------------------------------------------
// CommandLine
// ---------------------------------------------------------------------------
//
// Parsed command line: one command word, named options, and positionals.
// Every option (--name) consumes the following argument as its value.
// The parsed strings borrow argv; argv must outlive the CommandLine.
//
class CommandLine {
public:
    CommandLine();

    bool parse(int argc, char **argv);

    const char *command() const;

    const char *option(const char *name, const char *fallback) const;
    U64         option_u64(const char *name, U64 fallback) const;

    Size        positional_size() const;
    const char *positional(Size index) const;

private:
    const char  *command_word;
    OptionTable  options;
    ArgumentList positionals;
};

// Split one line into whitespace-separated words; double quotes group words.
// Fails on an unbalanced quote.
bool split_words(const char *line, Strings *words);

} // namespace lucia
