#include "encode.h"

#include <string.h>

namespace lucia {

namespace {

bool write_bytes(Bytes* out, const Byte* data, Size size)
{
  if (out == 0) {
    return false;
  }
  if (size == 0) {
    return true;
  }
  if (data == 0) {
    return false;
  }
  out->insert(out->end(), data, data + size);
  return true;
}

bool write_u8(Bytes* out, Byte value)
{
  if (out == 0) {
    return false;
  }
  out->push_back(value);
  return true;
}

bool write_u16(Bytes* out, U32 value)
{
  if (value > 0xffffu || out == 0) {
    return false;
  }
  out->push_back((Byte)(value & 0xff));
  out->push_back((Byte)((value >> 8) & 0xff));
  return true;
}

bool write_u32(Bytes* out, U32 value)
{
  if (out == 0) {
    return false;
  }
  out->push_back((Byte)(value & 0xff));
  out->push_back((Byte)((value >> 8) & 0xff));
  out->push_back((Byte)((value >> 16) & 0xff));
  out->push_back((Byte)((value >> 24) & 0xff));
  return true;
}

bool write_u64(Bytes* out, U64 value)
{
  if (out == 0) {
    return false;
  }
  for (int i = 0; i < 8; ++i) {
    out->push_back((Byte)((value >> (8 * i)) & 0xff));
  }
  return true;
}

bool write_s64(Bytes* out, S64 value)
{
  return write_u64(out, (U64)value);
}

bool write_f64(Bytes* out, double value)
{
  U64 bits = 0;
  memcpy(&bits, &value, sizeof(bits));
  return write_u64(out, bits);
}

bool write_string(Bytes* out, const String& text)
{
  if (text.size() > 0xffffu) {
    return false;
  }
  return write_u16(out, (U32)text.size()) &&
         write_bytes(out, (const Byte*)text.data(), text.size());
}

bool read_bytes(const Byte* data, Size size, Size* offset, Byte* out,
                Size count)
{
  if (data == 0 || offset == 0 || *offset + count > size) {
    return false;
  }
  if (count != 0 && out == 0) {
    return false;
  }
  if (count != 0) {
    memcpy(out, data + *offset, count);
  }
  *offset += count;
  return true;
}

bool read_u8(const Byte* data, Size size, Size* offset, Byte* value)
{
  return read_bytes(data, size, offset, value, 1);
}

bool read_u16(const Byte* data, Size size, Size* offset, U32* value)
{
  Byte raw[2];
  if (!read_bytes(data, size, offset, raw, 2) || value == 0) {
    return false;
  }
  *value = (U32)raw[0] | ((U32)raw[1] << 8);
  return true;
}

bool read_u32(const Byte* data, Size size, Size* offset, U32* value)
{
  Byte raw[4];
  if (!read_bytes(data, size, offset, raw, 4) || value == 0) {
    return false;
  }
  *value = (U32)raw[0] | ((U32)raw[1] << 8) | ((U32)raw[2] << 16) |
           ((U32)raw[3] << 24);
  return true;
}

bool read_u64(const Byte* data, Size size, Size* offset, U64* value)
{
  Byte raw[8];
  if (!read_bytes(data, size, offset, raw, 8) || value == 0) {
    return false;
  }
  U64 result = 0;
  for (int i = 0; i < 8; ++i) {
    result |= ((U64)raw[i] << (8 * i));
  }
  *value = result;
  return true;
}

bool read_s64(const Byte* data, Size size, Size* offset, S64* value)
{
  U64 raw = 0;
  if (!read_u64(data, size, offset, &raw) || value == 0) {
    return false;
  }
  *value = (S64)raw;
  return true;
}

bool read_f64(const Byte* data, Size size, Size* offset, double* value)
{
  U64 bits = 0;
  if (!read_u64(data, size, offset, &bits) || value == 0) {
    return false;
  }
  memcpy(value, &bits, sizeof(bits));
  return true;
}

bool read_string(const Byte* data, Size size, Size* offset, String* text)
{
  U32 length = 0;
  if (!read_u16(data, size, offset, &length) || text == 0) {
    return false;
  }
  if (*offset + length > size) {
    return false;
  }
  text->assign((const char*)(data + *offset), length);
  *offset += length;
  return true;
}

bool encode_value(const Value& value, Bytes* output)
{
  if (!write_u8(output, (Byte)value.kind())) {
    return false;
  }

  switch (value.kind()) {
  case VALUE_EMPTY:
    return true;
  case VALUE_BOOL:
    return write_u8(output, value.boolean() ? 1 : 0);
  case VALUE_INT:
    return write_s64(output, value.integer());
  case VALUE_FLOAT:
    return write_f64(output, value.real());
  case VALUE_STRING:
    return write_string(output, value.text());
  case VALUE_BYTES:
    if (value.bytes().size() > 0xffffffffu) {
      return false;
    }
    return write_u32(output, (U32)value.bytes().size()) &&
           write_bytes(output, value.bytes().data(), value.bytes().size());
  }

  return false;
}

bool decode_value(const Byte* data, Size size, Size* offset, Value* value)
{
  if (value == 0) {
    return false;
  }

  Byte kind = 0;
  if (!read_u8(data, size, offset, &kind)) {
    return false;
  }

  switch (kind) {
  case VALUE_EMPTY:
    *value = Value();
    return true;
  case VALUE_BOOL: {
    Byte flag = 0;
    if (!read_u8(data, size, offset, &flag)) {
      return false;
    }
    *value = Value(flag != 0);
    return true;
  }
  case VALUE_INT: {
    S64 number = 0;
    if (!read_s64(data, size, offset, &number)) {
      return false;
    }
    *value = Value(number);
    return true;
  }
  case VALUE_FLOAT: {
    double number = 0.0;
    if (!read_f64(data, size, offset, &number)) {
      return false;
    }
    *value = Value(number);
    return true;
  }
  case VALUE_STRING: {
    String text;
    if (!read_string(data, size, offset, &text)) {
      return false;
    }
    *value = Value(text);
    return true;
  }
  case VALUE_BYTES: {
    U32 length = 0;
    if (!read_u32(data, size, offset, &length)) {
      return false;
    }
    if (*offset + length > size) {
      return false;
    }
    *value = Value(data + *offset, length);
    *offset += length;
    return true;
  }
  }

  return false;
}

}  // namespace

bool encode_node(const Node& node, Bytes* output)
{
  if (output == 0 || node.id().is_unset()) {
    return false;
  }

  output->clear();
  if (!write_bytes(output, node.id().bytes(), NodeId::SIZE)) {
    return false;
  }
  if (!write_u32(output, (U32)node.size())) {
    return false;
  }

  for (Size i = 0; i < node.size(); ++i) {
    Port port;
    if (!node.at(i, &port)) {
      return false;
    }
    if (!write_string(output, port.name())) {
      return false;
    }
    if (!write_u8(output, (Byte)port.direction())) {
      return false;
    }
    if (!encode_value(port.value(), output)) {
      return false;
    }
  }

  return true;
}

bool decode_node(const Byte* data, Size size, Node* output)
{
  if (data == 0 || output == 0) {
    return false;
  }

  Size offset = 0;
  Byte id_bytes[NodeId::SIZE];
  if (!read_bytes(data, size, &offset, id_bytes, NodeId::SIZE)) {
    return false;
  }

  Node node;
  NodeId id;
  id.set_bytes(id_bytes);
  node.set_id(id);

  U32 port_count = 0;
  if (!read_u32(data, size, &offset, &port_count)) {
    return false;
  }

  for (U32 i = 0; i < port_count; ++i) {
    String name;
    Byte direction = 0;
    Value value;
    if (!read_string(data, size, &offset, &name)) {
      return false;
    }
    if (!read_u8(data, size, &offset, &direction)) {
      return false;
    }
    if (direction != PORT_IN && direction != PORT_OUT) {
      return false;
    }
    if (!decode_value(data, size, &offset, &value)) {
      return false;
    }
    if (!node.put(Port(name.c_str(), (PortDirection)direction, value))) {
      return false;
    }
  }

  if (offset != size) {
    return false;
  }

  *output = node;
  return true;
}

bool encode_fiber(const Fiber& fiber, Bytes* output)
{
  if (output == 0) {
    return false;
  }
  if (fiber.source().is_unset() || fiber.target().is_unset()) {
    return false;
  }
  if (fiber.source_port().empty() || fiber.target_port().empty()) {
    return false;
  }

  output->clear();
  return write_bytes(output, fiber.source().bytes(), NodeId::SIZE) &&
         write_string(output, fiber.source_port()) &&
         write_bytes(output, fiber.target().bytes(), NodeId::SIZE) &&
         write_string(output, fiber.target_port());
}

bool decode_fiber(const Byte* data, Size size, Fiber* output)
{
  if (data == 0 || output == 0) {
    return false;
  }

  Size offset = 0;
  Byte source_bytes[NodeId::SIZE];
  Byte target_bytes[NodeId::SIZE];
  String source_port;
  String target_port;

  if (!read_bytes(data, size, &offset, source_bytes, NodeId::SIZE) ||
      !read_string(data, size, &offset, &source_port) ||
      !read_bytes(data, size, &offset, target_bytes, NodeId::SIZE) ||
      !read_string(data, size, &offset, &target_port)) {
    return false;
  }
  if (offset != size) {
    return false;
  }

  NodeId source;
  NodeId target;
  source.set_bytes(source_bytes);
  target.set_bytes(target_bytes);

  Fiber fiber;
  fiber.set_source(source, source_port.c_str());
  fiber.set_target(target, target_port.c_str());
  *output = fiber;
  return true;
}

bool encode_graph(const Nodes& nodes, const Fibers& fibers, Bytes* output)
{
  if (output == 0) {
    return false;
  }

  output->clear();
  if (!write_bytes(output, (const Byte*)"LUGRF", 6)) {
    return false;
  }
  if (!write_u16(output, 1)) {
    return false;
  }
  if (!write_u32(output, (U32)nodes.size())) {
    return false;
  }

  for (Size i = 0; i < nodes.size(); ++i) {
    Bytes encoded;
    if (!encode_node(nodes[i], &encoded)) {
      return false;
    }
    if (!write_u32(output, (U32)encoded.size()) ||
        !write_bytes(output, encoded.data(), encoded.size())) {
      return false;
    }
  }

  if (!write_u32(output, (U32)fibers.size())) {
    return false;
  }

  for (Size i = 0; i < fibers.size(); ++i) {
    Bytes encoded;
    if (!encode_fiber(fibers[i], &encoded)) {
      return false;
    }
    if (!write_u32(output, (U32)encoded.size()) ||
        !write_bytes(output, encoded.data(), encoded.size())) {
      return false;
    }
  }

  return true;
}

bool decode_graph(const Byte* data, Size size, Nodes* nodes, Fibers* fibers)
{
  if (data == 0 || nodes == 0 || fibers == 0) {
    return false;
  }

  Size offset = 0;
  Byte magic[6];
  U32 version = 0;
  if (!read_bytes(data, size, &offset, magic, 6) ||
      memcmp(magic, "LUGRF", 6) != 0 ||
      !read_u16(data, size, &offset, &version) ||
      version != 1) {
    return false;
  }

  nodes->clear();
  fibers->clear();

  U32 node_count = 0;
  if (!read_u32(data, size, &offset, &node_count)) {
    return false;
  }

  for (U32 i = 0; i < node_count; ++i) {
    U32 encoded_size = 0;
    if (!read_u32(data, size, &offset, &encoded_size)) {
      return false;
    }
    if (offset + encoded_size > size) {
      return false;
    }
    Node node;
    if (!decode_node(data + offset, encoded_size, &node)) {
      return false;
    }
    offset += encoded_size;
    nodes->push_back(node);
  }

  U32 fiber_count = 0;
  if (!read_u32(data, size, &offset, &fiber_count)) {
    return false;
  }

  for (U32 i = 0; i < fiber_count; ++i) {
    U32 encoded_size = 0;
    if (!read_u32(data, size, &offset, &encoded_size)) {
      return false;
    }
    if (offset + encoded_size > size) {
      return false;
    }
    Fiber fiber;
    if (!decode_fiber(data + offset, encoded_size, &fiber)) {
      return false;
    }
    offset += encoded_size;
    fibers->push_back(fiber);
  }

  return offset == size;
}

}  // namespace lucia
