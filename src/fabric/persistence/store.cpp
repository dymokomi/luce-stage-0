#include "fabric/persistence/store.h"

#include <string.h>

namespace lucia {

namespace {

enum {
    STORE_VERSION                = 1,
    DESCRIPTOR_MAGIC_SIZE        = 8,
    DESCRIPTOR_VERSION_OFFSET    = 8,
    DESCRIPTOR_GENERATION_OFFSET = 16,
    DESCRIPTOR_BODY_SIZE_OFFSET  = 24,
    DESCRIPTOR_CHECKSUM_OFFSET   = 32,
    DESCRIPTOR_USED_SIZE         = 40
};

const Byte DESCRIPTOR_MAGIC[DESCRIPTOR_MAGIC_SIZE] = {'L', 'U', 'S', 'T',
                                                      'O', 'R', 'E', '\0'};

struct LoadedSnapshot {
    Texels      texels;
    BlobRecords blobs;
    U64         generation;
    int         arena;
    bool        valid;
};

String blob_key(const Byte *id) {
    return String(reinterpret_cast<const char *>(id), BlobRef::ID_SIZE);
}

void put_u32(Byte *data, U32 value) {
    for (int i = 0; i < 4; ++i) {
        data[i] = static_cast<Byte>((value >> (i * 8)) & 0xffu);
    }
}

void put_u64(Byte *data, U64 value) {
    for (int i = 0; i < 8; ++i) {
        data[i] = static_cast<Byte>((value >> (i * 8)) & 0xffu);
    }
}

U32 get_u32(const Byte *data) {
    return static_cast<U32>(data[0]) | (static_cast<U32>(data[1]) << 8) |
           (static_cast<U32>(data[2]) << 16) | (static_cast<U32>(data[3]) << 24);
}

U64 get_u64(const Byte *data) {
    U64 value = 0;
    for (int i = 0; i < 8; ++i) {
        value |= static_cast<U64>(data[i]) << (i * 8);
    }
    return value;
}

U64 arena_pages(const Volume *volume) {
    return (volume->size() - 2) / 2;
}

U64 arena_first(const Volume *volume, int arena) {
    return 2 + static_cast<U64>(arena) * arena_pages(volume);
}

U64 pages_for(Size byte_size) {
    if (byte_size == 0) {
        return 0;
    }
    return (static_cast<U64>(byte_size) + PAGE_SIZE - 1) / PAGE_SIZE;
}

// This checksum detects accidental corruption.  It is not authentication and
// must not be used as a security boundary.
U64 body_checksum(const Byte *data, Size size) {
    U64 hash = UINT64_C(1469598103934665603);
    for (Size i = 0; i < size; ++i) {
        hash ^= data[i];
        hash *= UINT64_C(1099511628211);
    }
    hash ^= static_cast<U64>(size);
    hash *= UINT64_C(1099511628211);
    return hash;
}

bool descriptor_tail_clear(const Byte *descriptor) {
    for (Size i = DESCRIPTOR_USED_SIZE; i < PAGE_SIZE; ++i) {
        if (descriptor[i] != 0) {
            return false;
        }
    }
    return true;
}

bool write_body(Volume *volume, int arena, const Bytes &body) {
    const U64 needed = pages_for(body.size());
    if (needed == 0 || needed > arena_pages(volume)) {
        return false;
    }

    Byte page[PAGE_SIZE];
    Size offset = 0;
    for (U64 i = 0; i < needed; ++i) {
        memset(page, 0, sizeof(page));
        const Size remaining = body.size() - offset;
        const Size chunk     = remaining < static_cast<Size>(PAGE_SIZE)
                                   ? remaining
                                   : static_cast<Size>(PAGE_SIZE);
        memcpy(page, body.data() + offset, chunk);
        if (!volume->write(arena_first(volume, arena) + i, page)) {
            return false;
        }
        offset += chunk;
    }
    return true;
}

bool write_descriptor(Volume *volume, int arena, U64 generation, const Bytes &body) {
    Byte descriptor[PAGE_SIZE];
    memset(descriptor, 0, sizeof(descriptor));
    memcpy(descriptor, DESCRIPTOR_MAGIC, sizeof(DESCRIPTOR_MAGIC));
    put_u32(descriptor + DESCRIPTOR_VERSION_OFFSET, STORE_VERSION);
    put_u64(descriptor + DESCRIPTOR_GENERATION_OFFSET, generation);
    put_u64(descriptor + DESCRIPTOR_BODY_SIZE_OFFSET, static_cast<U64>(body.size()));
    put_u64(descriptor + DESCRIPTOR_CHECKSUM_OFFSET,
            body_checksum(body.data(), body.size()));
    return volume->write(static_cast<U64>(arena), descriptor);
}

bool publish(Volume *volume, int arena, U64 generation, const Bytes &body) {
    if (!write_body(volume, arena, body) || !volume->flush()) {
        return false;
    }
    if (!write_descriptor(volume, arena, generation, body)) {
        return false;
    }
    return volume->flush();
}

bool read_body(Volume *volume, int arena, U64 byte_size, Bytes *body) {
    if (body == 0 || byte_size == 0 || byte_size > static_cast<U64>(SIZE_MAX)) {
        return false;
    }
    const U64 needed = (byte_size + static_cast<U64>(PAGE_SIZE) - 1) / PAGE_SIZE;
    if (needed == 0 || needed > arena_pages(volume)) {
        return false;
    }

    Bytes loaded;
    loaded.reserve(static_cast<Size>(byte_size));
    Byte page[PAGE_SIZE];
    U64  remaining = byte_size;
    for (U64 i = 0; i < needed; ++i) {
        if (!volume->read(arena_first(volume, arena) + i, page)) {
            return false;
        }
        const Size chunk = remaining < static_cast<U64>(PAGE_SIZE)
                               ? static_cast<Size>(remaining)
                               : static_cast<Size>(PAGE_SIZE);
        loaded.insert(loaded.end(), page, page + chunk);
        remaining -= chunk;
    }
    body->swap(loaded);
    return true;
}

bool load_snapshot(Volume *volume, int arena, LoadedSnapshot *loaded) {
    Byte descriptor[PAGE_SIZE];
    if (loaded == 0 || !volume->read(static_cast<U64>(arena), descriptor) ||
        memcmp(descriptor, DESCRIPTOR_MAGIC, sizeof(DESCRIPTOR_MAGIC)) != 0 ||
        get_u32(descriptor + DESCRIPTOR_VERSION_OFFSET) != STORE_VERSION ||
        get_u32(descriptor + 12) != 0 || !descriptor_tail_clear(descriptor)) {
        return false;
    }

    const U64 generation = get_u64(descriptor + DESCRIPTOR_GENERATION_OFFSET);
    const U64 byte_size  = get_u64(descriptor + DESCRIPTOR_BODY_SIZE_OFFSET);
    const U64 checksum   = get_u64(descriptor + DESCRIPTOR_CHECKSUM_OFFSET);
    if (generation == 0) {
        return false;
    }

    Bytes       body;
    Texels      texels;
    BlobRecords blobs;
    if (!read_body(volume, arena, byte_size, &body) ||
        body_checksum(body.data(), body.size()) != checksum ||
        !decode_snapshot(body.data(), body.size(), &texels, &blobs)) {
        return false;
    }

    loaded->texels.swap(texels);
    loaded->blobs.swap(blobs);
    loaded->generation = generation;
    loaded->arena      = arena;
    loaded->valid      = true;
    return true;
}

void tables_to_snapshot(const TexelTable &table, const BlobTable &blob_table,
                        Texels *texels, BlobRecords *blobs) {
    texels->clear();
    blobs->clear();
    for (TexelTable::const_iterator found = table.begin(); found != table.end(); ++found) {
        texels->push_back(found->second);
    }
    for (BlobTable::const_iterator found = blob_table.begin(); found != blob_table.end();
         ++found) {
        blobs->push_back(found->second);
    }
}

void snapshot_to_tables(const Texels &texels, const BlobRecords &blobs, TexelTable *table,
                        BlobTable *blob_table) {
    table->clear();
    blob_table->clear();
    for (Size i = 0; i < texels.size(); ++i) {
        (*table)[texels[i].id()] = texels[i];
    }
    for (Size i = 0; i < blobs.size(); ++i) {
        (*blob_table)[blob_key(blobs[i].reference.id())] = blobs[i];
    }
}

// A deterministic, non-security hash expanded into four independent words.
// Collisions are always checked against the original bytes.
void blob_identifier(const Bytes &bytes, Byte identifier[BlobRef::ID_SIZE]) {
    static const U64 seeds[4] = {UINT64_C(1469598103934665603), UINT64_C(1099511628211),
                                 UINT64_C(7809847782465536322),
                                 UINT64_C(9650029242287828579)};

    bool all_zero = true;
    for (int word = 0; word < 4; ++word) {
        U64 hash = seeds[word] ^ static_cast<U64>(bytes.size());
        for (Size i = 0; i < bytes.size(); ++i) {
            hash ^= static_cast<U64>(bytes[i]) + (static_cast<U64>(word + 1) << 8);
            hash *= UINT64_C(1099511628211);
            hash ^= hash >> 29;
        }
        hash ^= static_cast<U64>(word + 1) * UINT64_C(0x9e3779b97f4a7c15);
        for (int byte = 0; byte < 8; ++byte) {
            identifier[word * 8 + byte] = static_cast<Byte>((hash >> (byte * 8)) & 0xffu);
            if (identifier[word * 8 + byte] != 0) {
                all_zero = false;
            }
        }
    }
    if (all_zero) {
        identifier[BlobRef::ID_SIZE - 1] = 1;
    }
}

} // namespace

Transaction::Transaction()
    : store(0), base_generation(0), next_revision(0), active(false) {}

bool Transaction::is_active() const {
    return active;
}

Size Transaction::size() const {
    return active ? texels.size() : 0;
}

bool Transaction::at(Size index, Texel *texel) const {
    if (!active || texel == 0 || index >= texels.size()) {
        return false;
    }
    TexelTable::const_iterator found = texels.begin();
    for (Size i = 0; i < index; ++i) {
        ++found;
    }
    *texel = found->second;
    return true;
}

bool Transaction::has(const TexelId &id) const {
    return active && !id.is_unset() && texels.find(id) != texels.end();
}

bool Transaction::get(const TexelId &id, Texel *texel) const {
    if (!active || texel == 0 || id.is_unset()) {
        return false;
    }
    TexelTable::const_iterator found = texels.find(id);
    if (found == texels.end()) {
        return false;
    }
    *texel = found->second;
    return true;
}

bool Transaction::put_changed(const Texel &texel) {
    if (!active || !texel.valid() || next_revision == 0) {
        return false;
    }
    Texel changed = texel;
    changed.set_revision(next_revision);
    if (next_revision == static_cast<U64>(-1)) {
        next_revision = 0;
    } else {
        ++next_revision;
    }
    texels[changed.id()] = changed;
    touched.insert(changed.id());
    return true;
}

bool Transaction::put(const Texel &texel) {
    return put_changed(texel);
}

bool Transaction::referenced(const TexelId &id) const {
    for (TexelTable::const_iterator found = texels.begin(); found != texels.end();
         ++found) {
        const Texel &texel = found->second;
        if (texel.has_content() && texel.content().type() == VALUE_TEXEL &&
            texel.content().texel().equals(id)) {
            return true;
        }
        for (Size i = 0; i < texel.input_size(); ++i) {
            InputPort input;
            if (texel.input_at(i, &input) && input.has_binding() &&
                input.binding().source().equals(id)) {
                return true;
            }
        }
        for (Size i = 0; i < texel.output_size(); ++i) {
            OutputPort output;
            if (texel.output_at(i, &output) && output.has_source() &&
                output.source().type() == VALUE_TEXEL &&
                output.source().texel().equals(id)) {
                return true;
            }
        }
    }
    return false;
}

bool Transaction::remove(const TexelId &id) {
    if (!active || id.is_unset() || texels.find(id) == texels.end() || referenced(id)) {
        return false;
    }
    texels.erase(id);
    touched.insert(id);
    return true;
}

bool Transaction::connect(const TexelId &target, const char *input_name,
                          const TexelId &source, const char *output_name) {
    if (!active || input_name == 0 || output_name == 0 || target.is_unset() ||
        source.is_unset()) {
        return false;
    }
    TexelTable::iterator       target_texel = texels.find(target);
    TexelTable::const_iterator source_texel = texels.find(source);
    if (target_texel == texels.end() || source_texel == texels.end()) {
        return false;
    }

    Texel      changed = target_texel->second;
    InputPort  input;
    OutputPort output;
    if (!changed.get_input(input_name, &input) ||
        !source_texel->second.get_output(output_name, &output) ||
        input.type() != output.type() || !input.bind(Fiber(source, output_name)) ||
        !changed.put_input(input)) {
        return false;
    }
    return put_changed(changed);
}

bool Transaction::disconnect(const TexelId &target, const char *input_name) {
    if (!active || input_name == 0 || target.is_unset()) {
        return false;
    }
    TexelTable::iterator target_texel = texels.find(target);
    if (target_texel == texels.end()) {
        return false;
    }
    Texel     changed = target_texel->second;
    InputPort input;
    if (!changed.get_input(input_name, &input) || !input.has_binding()) {
        return false;
    }
    input.unbind();
    if (!changed.put_input(input)) {
        return false;
    }
    return put_changed(changed);
}

bool Transaction::put_blob(const Bytes &bytes, BlobRef *reference) {
    if (!active || reference == 0) {
        return false;
    }
    Byte id[BlobRef::ID_SIZE];
    blob_identifier(bytes, id);
    const String              key   = blob_key(id);
    BlobTable::const_iterator found = blobs.find(key);
    if (found != blobs.end()) {
        if (found->second.bytes != bytes) {
            return false;
        }
        *reference = found->second.reference;
        return true;
    }

    BlobRecord record;
    record.reference = BlobRef(id, static_cast<U64>(bytes.size()));
    record.bytes     = bytes;
    blobs[key]       = record;
    *reference       = record.reference;
    return true;
}

bool Transaction::get_blob(const BlobRef &reference, Bytes *bytes) const {
    if (!active || bytes == 0 || reference.is_unset()) {
        return false;
    }
    BlobTable::const_iterator found = blobs.find(blob_key(reference.id()));
    if (found == blobs.end() || found->second.reference.size() != reference.size()) {
        return false;
    }
    *bytes = found->second.bytes;
    return true;
}

bool Transaction::commit() {
    return active && store != 0 && store->commit(this);
}

bool Transaction::abort() {
    if (!active) {
        return false;
    }
    texels.clear();
    blobs.clear();
    store           = 0;
    base_generation = 0;
    next_revision   = 0;
    active          = false;
    return true;
}

Store::Store() : volume(0), store_generation(0), active_arena(-1), open_flag(false) {}

bool Store::create(Volume *store_volume) {
    if (store_volume == 0 || store_volume->size() < 6) {
        return false;
    }

    Byte empty_descriptor[PAGE_SIZE];
    memset(empty_descriptor, 0, sizeof(empty_descriptor));
    if (!store_volume->write(0, empty_descriptor) ||
        !store_volume->write(1, empty_descriptor) || !store_volume->flush()) {
        return false;
    }

    Texels      empty_texels;
    BlobRecords empty_blobs;
    Bytes       body;
    if (!encode_snapshot(empty_texels, empty_blobs, &body) ||
        !publish(store_volume, 0, 1, body)) {
        return false;
    }

    volume = store_volume;
    texels.clear();
    blobs.clear();
    changes.clear();
    store_generation = 1;
    active_arena     = 0;
    open_flag        = true;
    return true;
}

bool Store::open(Volume *store_volume) {
    if (store_volume == 0 || store_volume->size() < 6) {
        return false;
    }

    LoadedSnapshot first;
    LoadedSnapshot second;
    first.valid  = false;
    second.valid = false;
    load_snapshot(store_volume, 0, &first);
    load_snapshot(store_volume, 1, &second);
    if (!first.valid && !second.valid) {
        return false;
    }
    if (first.valid && second.valid && first.generation == second.generation) {
        return false;
    }

    const LoadedSnapshot *newest = 0;
    if (first.valid && (!second.valid || first.generation > second.generation)) {
        newest = &first;
    } else {
        newest = &second;
    }

    TexelTable loaded_texels;
    BlobTable  loaded_blobs;
    snapshot_to_tables(newest->texels, newest->blobs, &loaded_texels, &loaded_blobs);
    volume = store_volume;
    texels.swap(loaded_texels);
    blobs.swap(loaded_blobs);
    changes.clear();
    store_generation = newest->generation;
    active_arena     = newest->arena;
    open_flag        = true;
    return true;
}

bool Store::is_open() const {
    return open_flag;
}

U64 Store::generation() const {
    return open_flag ? store_generation : 0;
}

Size Store::size() const {
    return open_flag ? texels.size() : 0;
}

bool Store::at(Size index, Texel *texel) const {
    if (!open_flag || texel == 0 || index >= texels.size()) {
        return false;
    }
    TexelTable::const_iterator found = texels.begin();
    for (Size i = 0; i < index; ++i) {
        ++found;
    }
    *texel = found->second;
    return true;
}

bool Store::has(const TexelId &id) const {
    return open_flag && !id.is_unset() && texels.find(id) != texels.end();
}

bool Store::get(const TexelId &id, Texel *texel) const {
    if (!open_flag || texel == 0 || id.is_unset()) {
        return false;
    }
    TexelTable::const_iterator found = texels.find(id);
    if (found == texels.end()) {
        return false;
    }
    *texel = found->second;
    return true;
}

bool Store::get_blob(const BlobRef &reference, Bytes *bytes) const {
    if (!open_flag || bytes == 0 || reference.is_unset()) {
        return false;
    }
    BlobTable::const_iterator found = blobs.find(blob_key(reference.id()));
    if (found == blobs.end() || found->second.reference.size() != reference.size()) {
        return false;
    }
    *bytes = found->second.bytes;
    return true;
}

bool Store::begin(Transaction *transaction) {
    if (!open_flag || transaction == 0 || transaction->active) {
        return false;
    }

    U64 highest_revision = 0;
    for (TexelTable::const_iterator found = texels.begin(); found != texels.end();
         ++found) {
        if (found->second.revision() > highest_revision) {
            highest_revision = found->second.revision();
        }
    }

    transaction->store           = this;
    transaction->texels          = texels;
    transaction->blobs           = blobs;
    transaction->base_generation = store_generation;
    transaction->touched.clear();
    transaction->next_revision =
        highest_revision == static_cast<U64>(-1) ? 0 : highest_revision + 1;
    transaction->active = true;
    return true;
}

bool Store::commit(Transaction *transaction) {
    if (!open_flag || transaction == 0 || !transaction->active ||
        transaction->store != this || transaction->base_generation != store_generation ||
        store_generation == static_cast<U64>(-1)) {
        return false;
    }

    Texels      snapshot_texels;
    BlobRecords snapshot_blobs;
    tables_to_snapshot(transaction->texels, transaction->blobs, &snapshot_texels,
                       &snapshot_blobs);
    Bytes body;
    if (!validate_snapshot(snapshot_texels, snapshot_blobs) ||
        !encode_snapshot(snapshot_texels, snapshot_blobs, &body)) {
        return false;
    }

    const int inactive_arena = active_arena == 0 ? 1 : 0;
    const U64 new_generation = store_generation + 1;
    if (!publish(volume, inactive_arena, new_generation, body)) {
        return false;
    }

    texels.swap(transaction->texels);
    blobs.swap(transaction->blobs);
    store_generation = new_generation;
    active_arena     = inactive_arena;
    record_changes(transaction->touched);

    transaction->store           = 0;
    transaction->base_generation = 0;
    transaction->next_revision   = 0;
    transaction->active          = false;
    return true;
}

bool Store::observe(const TexelId &id, const char *output_name, const Value &value) {
    if (!open_flag || output_name == 0 || id.is_unset() ||
        store_generation == static_cast<U64>(-1)) {
        return false;
    }
    TexelTable::iterator found = texels.find(id);
    if (found == texels.end()) {
        return false;
    }

    Texel      changed = found->second;
    OutputPort output;
    if (!changed.get_output(output_name, &output) || !output.set_source(value) ||
        !changed.put_output(output)) {
        return false;
    }

    U64 highest_revision = 0;
    for (TexelTable::const_iterator texel = texels.begin(); texel != texels.end();
         ++texel) {
        if (texel->second.revision() > highest_revision) {
            highest_revision = texel->second.revision();
        }
    }
    if (highest_revision == static_cast<U64>(-1)) {
        return false;
    }

    changed.set_revision(highest_revision + 1);
    found->second = changed;
    ++store_generation;

    TexelIdSet observed;
    observed.insert(id);
    record_changes(observed);
    return true;
}

bool Store::changes_since(U64 generation, TexelIdList *changed) const {
    if (!open_flag || changed == 0 || generation > store_generation) {
        return false;
    }
    changed->clear();
    if (generation == store_generation) {
        return true;
    }
    if (changes.empty() || changes.front().generation > generation + 1) {
        return false;
    }

    TexelIdSet united;
    for (ChangeSets::const_iterator set = changes.begin(); set != changes.end(); ++set) {
        if (set->generation <= generation) {
            continue;
        }
        united.insert(set->changed.begin(), set->changed.end());
    }
    changed->assign(united.begin(), united.end());
    return true;
}

void Store::record_changes(const TexelIdSet &changed) {
    ChangeSet set;
    set.generation = store_generation;
    set.changed.assign(changed.begin(), changed.end());
    changes.push_back(set);
    if (changes.size() > CHANGE_RING) {
        changes.erase(changes.begin());
    }
}

} // namespace lucia
