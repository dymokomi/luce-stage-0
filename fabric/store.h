#pragma once

#include "fiber.h"
#include "node.h"
#include "principal.h"
#include "types.h"
#include "volume.h"

namespace lucia {

typedef std::map<NodeId, Node> NodeTable;
typedef std::vector<Fiber>     FiberList;

// ---------------------------------------------------------------------------
// Store
// ---------------------------------------------------------------------------
//
// Durable fabric graph on a page Volume.  Mutations stay in memory until
// flush: encode → sign(principal) → seal(principal) → pages.
//
// Page 0 is the header.  Pages 1… hold the sealed graph body.
//
class Store {
public:
  Store();

  bool create(Volume* volume, const Principal& who);
  bool open  (Volume* volume, const Principal& who);

  bool is_open() const;

  Size node_count() const;
  Size fiber_count() const;

  bool has_node(const NodeId& id) const;
  bool get_node(const NodeId& id, Node* node) const;
  bool put_node(const Node& node);
  bool remove_node(const NodeId& id);

  bool put_fiber(const Fiber& fiber);
  bool fiber_at(Size index, Fiber* fiber) const;
  bool remove_fiber(Size index);

  bool flush();

private:
  Store(const Store&);
  Store& operator=(const Store&);

  bool write_pages(const Bytes& sealed) const;
  bool read_pages(Bytes* sealed) const;

  Volume*         volume;
  Principal       owner;
  NodeTable       nodes;
  FiberList       fibers;
  bool            open_flag;
};

}  // namespace lucia
