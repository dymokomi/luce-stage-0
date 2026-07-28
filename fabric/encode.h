#pragma once

#include "fiber.h"
#include "node.h"
#include "types.h"

namespace lucia {

typedef std::vector<Node>  Nodes;
typedef std::vector<Fiber> Fibers;

// ---------------------------------------------------------------------------
// Graph binary encoding
// ---------------------------------------------------------------------------
//
// Deterministic little-endian layout for nodes and fibers.
// Magic is "LUGRF\0", version 1.
//
bool encode_node(const Node& node, Bytes* output);
bool decode_node(const Byte* data, Size size, Node* output);

bool encode_fiber(const Fiber& fiber, Bytes* output);
bool decode_fiber(const Byte* data, Size size, Fiber* output);

bool encode_graph(const Nodes& nodes, const Fibers& fibers, Bytes* output);
bool decode_graph(const Byte* data, Size size, Nodes* nodes, Fibers* fibers);

}  // namespace lucia
