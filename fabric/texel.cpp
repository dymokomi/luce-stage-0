#include "texel.h"

namespace lucia {

Texel::Texel()
    : texel_revision(0)
{
}

Texel::Texel(const TexelId& id)
    : texel_id(id),
      texel_revision(0)
{
}

const TexelId& Texel::id() const
{
  return texel_id;
}

void Texel::set_id(const TexelId& id)
{
  texel_id = id;
}

bool Texel::has_content() const
{
  return content_value.type() != VALUE_NONE;
}

const Value& Texel::content() const
{
  return content_value;
}

bool Texel::set_content(const Value& value)
{
  if (value.type() == VALUE_NONE) {
    return false;
  }
  content_value = value;
  return true;
}

void Texel::clear_content()
{
  content_value = Value();
}

const String& Texel::evaluator() const
{
  return evaluator_name;
}

bool Texel::set_evaluator(const char* name)
{
  if (name == 0 || name[0] == '\0') {
    return false;
  }
  evaluator_name = name;
  return true;
}

U64 Texel::revision() const
{
  return texel_revision;
}

void Texel::set_revision(U64 revision)
{
  texel_revision = revision;
}

Size Texel::input_size() const
{
  return inputs.size();
}

bool Texel::has_input(const char* name) const
{
  return name != 0 && inputs.find(name) != inputs.end();
}

bool Texel::get_input(const char* name, InputPort* port) const
{
  if (name == 0 || port == 0) {
    return false;
  }

  InputPortMap::const_iterator found = inputs.find(name);
  if (found == inputs.end()) {
    return false;
  }
  *port = found->second;
  return true;
}

bool Texel::put_input(const InputPort& port)
{
  if (!port.valid()) {
    return false;
  }
  inputs[port.name()] = port;
  return true;
}

bool Texel::remove_input(const char* name)
{
  return name != 0 && inputs.erase(name) > 0;
}

bool Texel::input_at(Size index, InputPort* port) const
{
  if (port == 0 || index >= inputs.size()) {
    return false;
  }

  InputPortMap::const_iterator found = inputs.begin();
  for (Size i = 0; i < index; ++i) {
    ++found;
  }
  *port = found->second;
  return true;
}

Size Texel::output_size() const
{
  return outputs.size();
}

bool Texel::has_output(const char* name) const
{
  return name != 0 && outputs.find(name) != outputs.end();
}

bool Texel::get_output(const char* name, OutputPort* port) const
{
  if (name == 0 || port == 0) {
    return false;
  }

  OutputPortMap::const_iterator found = outputs.find(name);
  if (found == outputs.end()) {
    return false;
  }
  *port = found->second;
  return true;
}

bool Texel::put_output(const OutputPort& port)
{
  if (!port.valid()) {
    return false;
  }
  outputs[port.name()] = port;
  return true;
}

bool Texel::remove_output(const char* name)
{
  return name != 0 && outputs.erase(name) > 0;
}

bool Texel::output_at(Size index, OutputPort* port) const
{
  if (port == 0 || index >= outputs.size()) {
    return false;
  }

  OutputPortMap::const_iterator found = outputs.begin();
  for (Size i = 0; i < index; ++i) {
    ++found;
  }
  *port = found->second;
  return true;
}

bool Texel::valid() const
{
  if (texel_id.is_unset()) {
    return false;
  }

  InputPortMap::const_iterator input = inputs.begin();
  for (; input != inputs.end(); ++input) {
    if (input->first != input->second.name() || !input->second.valid()) {
      return false;
    }
  }

  OutputPortMap::const_iterator output = outputs.begin();
  for (; output != outputs.end(); ++output) {
    if (output->first != output->second.name() || !output->second.valid()) {
      return false;
    }
  }
  return true;
}

}  // namespace lucia
