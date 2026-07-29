#pragma once

#include "base/types.h"
#include "fabric/model/input_port.h"
#include "fabric/model/output_port.h"
#include "fabric/model/texel_id.h"
#include "fabric/model/value.h"

namespace lucia {

typedef std::map<String, InputPort>  InputPortMap;
typedef std::map<String, OutputPort> OutputPortMap;

// ---------------------------------------------------------------------------
// Texel
// ---------------------------------------------------------------------------
//
// Fabric primitive with stable identity, evaluator, content, and typed ports.
//
class Texel {
public:
    Texel();
    explicit Texel(const TexelId &id);

    const TexelId &id() const;
    void           set_id(const TexelId &id);

    bool         has_content() const;
    const Value &content() const;
    bool         set_content(const Value &value);
    void         clear_content();

    const String &evaluator() const;
    bool          set_evaluator(const char *name);

    U64  revision() const;
    void set_revision(U64 revision);

    Size input_size() const;
    bool has_input(const char *name) const;
    bool get_input(const char *name, InputPort *port) const;
    bool put_input(const InputPort &port);
    bool remove_input(const char *name);
    bool input_at(Size index, InputPort *port) const;

    Size output_size() const;
    bool has_output(const char *name) const;
    bool get_output(const char *name, OutputPort *port) const;
    bool put_output(const OutputPort &port);
    bool remove_output(const char *name);
    bool output_at(Size index, OutputPort *port) const;

    bool valid() const;

private:
    TexelId       texel_id;
    Value         content_value;
    String        evaluator_name;
    InputPortMap  inputs;
    OutputPortMap outputs;
    U64           texel_revision;
};

} // namespace lucia
