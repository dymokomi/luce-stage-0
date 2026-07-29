#pragma once

#include "base/types.h"
#include "fabric/model/texel.h"
#include "fabric/persistence/encode.h"
#include "storage/volume/volume.h"

namespace lucia {

typedef std::map<TexelId, Texel>     TexelTable;
typedef std::map<String, BlobRecord> BlobTable;

class Store;

// ---------------------------------------------------------------------------
// Transaction
// ---------------------------------------------------------------------------
//
// Private working snapshot.  Changes become visible only after commit has
// durably published a new Store generation.
//
class Transaction {
public:
    Transaction();

    bool is_active() const;

    Size size() const;
    bool at(Size index, Texel *texel) const;
    bool has(const TexelId &id) const;
    bool get(const TexelId &id, Texel *texel) const;
    bool put(const Texel &texel);
    bool remove(const TexelId &id);

    bool connect(const TexelId &target, const char *input, const TexelId &source,
                 const char *output);
    bool disconnect(const TexelId &target, const char *input);

    bool put_blob(const Bytes &bytes, BlobRef *reference);
    bool get_blob(const BlobRef &reference, Bytes *bytes) const;

    bool commit();
    bool abort();

private:
    friend class Store;

    Transaction(const Transaction &);
    Transaction &operator=(const Transaction &);

    bool put_changed(const Texel &texel);
    bool referenced(const TexelId &id) const;

    Store     *store;
    TexelTable texels;
    BlobTable  blobs;
    U64        base_generation;
    U64        next_revision;
    bool       active;
};

// ---------------------------------------------------------------------------
// Store
// ---------------------------------------------------------------------------
//
// Durable Texel snapshot using two descriptor pages and two body arenas.
//
class Store {
public:
    Store();

    // The Volume must outlive this Store and every Transaction begun from it.
    bool create(Volume *volume);
    bool open(Volume *volume);

    bool is_open() const;
    U64  generation() const;

    Size size() const;
    bool at(Size index, Texel *texel) const;
    bool has(const TexelId &id) const;
    bool get(const TexelId &id, Texel *texel) const;
    bool get_blob(const BlobRef &reference, Bytes *bytes) const;

    bool begin(Transaction *transaction);

private:
    friend class Transaction;

    Store(const Store &);
    Store &operator=(const Store &);

    bool commit(Transaction *transaction);

    Volume    *volume;
    TexelTable texels;
    BlobTable  blobs;
    U64        store_generation;
    int        active_arena;
    bool       open_flag;
};

} // namespace lucia
