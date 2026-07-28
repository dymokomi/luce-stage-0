#include "store.h"

#include "encode.h"
#include "seal.h"

#include <string.h>

namespace lucia {

namespace {

enum {
  STORE_VERSION      = 1,
  HEADER_PAGE        = 0,
  BODY_FIRST_PAGE    = 1,
  HEADER_MAGIC_SIZE  = 6,
  HEADER_SIG_OFFSET  = 56,
  HEADER_SIZE_OFFSET = 8
};

const char STORE_MAGIC[HEADER_MAGIC_SIZE] = {
  'L', 'U', 'F', 'A', 'B', '\0'
};

U64 pages_for_bytes(Size byte_count)
{
  if (byte_count == 0) {
    return 0;
  }
  return ((U64)byte_count + (U64)PAGE_SIZE - 1) / (U64)PAGE_SIZE;
}

}  // namespace

Store::Store()
    : volume(0),
      open_flag(false)
{
}

bool Store::create(Volume* store_volume, const Principal& who)
{
  if (store_volume == 0 || who.is_unset()) {
    return false;
  }
  if (store_volume->size() < 2) {
    return false;
  }

  volume = store_volume;
  owner = who;
  nodes.clear();
  fibers.clear();
  open_flag = true;
  return flush();
}

bool Store::open(Volume* store_volume, const Principal& who)
{
  if (store_volume == 0 || who.is_unset()) {
    return false;
  }
  if (store_volume->size() < 2) {
    return false;
  }

  Byte header[PAGE_SIZE];
  memset(header, 0, PAGE_SIZE);
  if (!store_volume->read(HEADER_PAGE, header)) {
    return false;
  }
  if (memcmp(header, STORE_MAGIC, HEADER_MAGIC_SIZE) != 0) {
    return false;
  }

  const U32 version =
      (U32)header[6] | ((U32)header[7] << 8);
  if (version != STORE_VERSION) {
    return false;
  }

  PublicKey author;
  author.set_bytes(header + 24);
  if (!author.equals(who.public_key())) {
    return false;
  }

  volume = store_volume;
  owner = who;

  Bytes sealed;
  if (!read_pages(&sealed)) {
    volume = 0;
    open_flag = false;
    return false;
  }

  Bytes plain;
  if (!unseal(sealed.data(), sealed.size(), who.seal_key(), KEY_SIZE,
              &plain)) {
    volume = 0;
    open_flag = false;
    return false;
  }

  Byte signature[SIGNATURE_SIZE];
  memcpy(signature, header + HEADER_SIG_OFFSET, SIGNATURE_SIZE);
  if (!verify(plain.data(), plain.size(), who.public_key(), signature)) {
    volume = 0;
    open_flag = false;
    return false;
  }

  Nodes loaded_nodes;
  Fibers loaded_fibers;
  if (!decode_graph(plain.data(), plain.size(), &loaded_nodes,
                    &loaded_fibers)) {
    volume = 0;
    open_flag = false;
    return false;
  }

  nodes.clear();
  for (Size i = 0; i < loaded_nodes.size(); ++i) {
    nodes[loaded_nodes[i].id()] = loaded_nodes[i];
  }
  fibers = loaded_fibers;
  open_flag = true;
  return true;
}

bool Store::is_open() const
{
  return open_flag;
}

Size Store::node_count() const
{
  return nodes.size();
}

Size Store::fiber_count() const
{
  return fibers.size();
}

bool Store::has_node(const NodeId& id) const
{
  return nodes.find(id) != nodes.end();
}

bool Store::get_node(const NodeId& id, Node* node) const
{
  if (node == 0) {
    return false;
  }
  NodeTable::const_iterator found = nodes.find(id);
  if (found == nodes.end()) {
    return false;
  }
  *node = found->second;
  return true;
}

bool Store::put_node(const Node& node)
{
  if (!open_flag || node.id().is_unset()) {
    return false;
  }
  nodes[node.id()] = node;
  return true;
}

bool Store::remove_node(const NodeId& id)
{
  if (!open_flag) {
    return false;
  }
  return nodes.erase(id) > 0;
}

bool Store::put_fiber(const Fiber& fiber)
{
  if (!open_flag) {
    return false;
  }
  if (fiber.source().is_unset() || fiber.target().is_unset()) {
    return false;
  }
  if (fiber.source_port().empty() || fiber.target_port().empty()) {
    return false;
  }
  fibers.push_back(fiber);
  return true;
}

bool Store::fiber_at(Size index, Fiber* fiber) const
{
  if (fiber == 0 || index >= fibers.size()) {
    return false;
  }
  *fiber = fibers[index];
  return true;
}

bool Store::remove_fiber(Size index)
{
  if (!open_flag || index >= fibers.size()) {
    return false;
  }
  fibers.erase(fibers.begin() + (FiberList::difference_type)index);
  return true;
}

bool Store::flush()
{
  if (!open_flag || volume == 0 || owner.is_unset()) {
    return false;
  }

  Nodes snapshot;
  snapshot.reserve(nodes.size());
  for (NodeTable::const_iterator it = nodes.begin(); it != nodes.end();
       ++it) {
    snapshot.push_back(it->second);
  }

  Bytes plain;
  if (!encode_graph(snapshot, fibers, &plain)) {
    return false;
  }

  Byte signature[SIGNATURE_SIZE];
  memset(signature, 0, SIGNATURE_SIZE);
  if (!sign(plain.data(), plain.size(), owner.keys(), signature)) {
    return false;
  }

  Bytes sealed;
  if (!seal(plain.data(), plain.size(), owner.seal_key(), KEY_SIZE,
            &sealed)) {
    return false;
  }

  if (!write_pages(sealed)) {
    return false;
  }

  Byte header[PAGE_SIZE];
  memset(header, 0, PAGE_SIZE);
  memcpy(header, STORE_MAGIC, HEADER_MAGIC_SIZE);
  header[6] = (Byte)(STORE_VERSION & 0xff);
  header[7] = (Byte)((STORE_VERSION >> 8) & 0xff);

  const U64 sealed_size = (U64)sealed.size();
  const U64 sealed_pages = pages_for_bytes(sealed.size());
  for (int i = 0; i < 8; ++i) {
    header[HEADER_SIZE_OFFSET + i] = (Byte)((sealed_size >> (8 * i)) & 0xff);
    header[16 + i] = (Byte)((sealed_pages >> (8 * i)) & 0xff);
  }

  memcpy(header + 24, owner.public_key().bytes(), KEY_SIZE);
  memcpy(header + HEADER_SIG_OFFSET, signature, SIGNATURE_SIZE);

  if (!volume->write(HEADER_PAGE, header)) {
    return false;
  }
  return volume->flush();
}

bool Store::write_pages(const Bytes& sealed) const
{
  const U64 needed = pages_for_bytes(sealed.size());
  if (needed + BODY_FIRST_PAGE > volume->size()) {
    return false;
  }

  Byte page[PAGE_SIZE];
  Size offset = 0;
  for (U64 page_index = 0; page_index < needed; ++page_index) {
    memset(page, 0, PAGE_SIZE);
    const Size remaining = sealed.size() - offset;
    const Size chunk = remaining < (Size)PAGE_SIZE ? remaining : (Size)PAGE_SIZE;
    if (chunk != 0) {
      memcpy(page, sealed.data() + offset, chunk);
      offset += chunk;
    }
    if (!volume->write(BODY_FIRST_PAGE + page_index, page)) {
      return false;
    }
  }
  return true;
}

bool Store::read_pages(Bytes* sealed) const
{
  if (sealed == 0 || volume == 0) {
    return false;
  }

  Byte header[PAGE_SIZE];
  if (!volume->read(HEADER_PAGE, header)) {
    return false;
  }

  U64 sealed_size = 0;
  U64 sealed_pages = 0;
  for (int i = 0; i < 8; ++i) {
    sealed_size |= ((U64)header[HEADER_SIZE_OFFSET + i] << (8 * i));
    sealed_pages |= ((U64)header[16 + i] << (8 * i));
  }

  if (sealed_pages == 0 ||
      BODY_FIRST_PAGE + sealed_pages > volume->size()) {
    return false;
  }
  if (pages_for_bytes((Size)sealed_size) != sealed_pages) {
    return false;
  }

  sealed->clear();
  sealed->reserve((Size)sealed_size);

  Byte page[PAGE_SIZE];
  Size remaining = (Size)sealed_size;
  for (U64 page_index = 0; page_index < sealed_pages; ++page_index) {
    if (!volume->read(BODY_FIRST_PAGE + page_index, page)) {
      return false;
    }
    const Size chunk =
        remaining < (Size)PAGE_SIZE ? remaining : (Size)PAGE_SIZE;
    sealed->insert(sealed->end(), page, page + chunk);
    remaining -= chunk;
  }
  return sealed->size() == (Size)sealed_size;
}

}  // namespace lucia
