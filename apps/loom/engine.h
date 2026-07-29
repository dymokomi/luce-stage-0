#pragma once

#include <string.h>

#include "base/types.h"
#include "loom.h"

// ---------------------------------------------------------------------------
// engine.h
// ---------------------------------------------------------------------------
//
// The terminal's view of the Loom engine: thin RAII C++ over the C ABI in
// zig/abi/loom.h.  Everything below the border is Zig; this file and the
// terminal above it never include engine internals.

namespace lucia {

// ---------------------------------------------------------------------------
// Id
// ---------------------------------------------------------------------------
//
// A texel identity at the border: 32 raw bytes.
//
struct Id {
    Byte bytes[LOOM_ID_SIZE];

    Id() {
        memset(bytes, 0, sizeof(bytes));
    }

    static Id generate() {
        Id id;
        loom_id_generate(id.bytes);
        return id;
    }

    bool parse(const char *text) {
        return loom_id_parse(text, bytes) == LOOM_OK;
    }

    String format() const {
        char text[LOOM_ID_TEXT_SIZE + 1];
        loom_id_format(bytes, text);
        return String(text);
    }

    bool is_unset() const {
        for (Size i = 0; i < LOOM_ID_SIZE; ++i) {
            if (bytes[i] != 0) {
                return false;
            }
        }
        return true;
    }

    bool equals(const Id &other) const {
        return memcmp(bytes, other.bytes, LOOM_ID_SIZE) == 0;
    }
};

// ---------------------------------------------------------------------------
// ValueBox
// ---------------------------------------------------------------------------
//
// A typed value plus the storage its text or bytes borrow.  The raw value
// stays valid while the box is alive; the engine copies what it keeps.
//
struct ValueBox {
    loom_value raw;
    String     storage;

    ValueBox() {
        memset(&raw, 0, sizeof(raw));
    }

    void set_bool(bool flag) {
        raw.tag     = LOOM_VALUE_BOOL;
        raw.boolean = flag;
    }

    void set_int(S64 number) {
        raw.tag     = LOOM_VALUE_INT;
        raw.integer = number;
    }

    void set_real(double number) {
        raw.tag  = LOOM_VALUE_REAL;
        raw.real = number;
    }

    void set_text(const String &text) {
        storage       = text;
        raw.tag       = LOOM_VALUE_TEXT;
        raw.data.data = reinterpret_cast<Byte *>(&storage[0]);
        raw.data.size = storage.size();
    }

    void set_bytes(const String &bytes) {
        storage       = bytes;
        raw.tag       = LOOM_VALUE_BYTES;
        raw.data.data = reinterpret_cast<Byte *>(&storage[0]);
        raw.data.size = storage.size();
    }

    void set_texel(const Id &id) {
        raw.tag = LOOM_VALUE_TEXEL;
        memcpy(raw.texel, id.bytes, LOOM_ID_SIZE);
    }
};

// ---------------------------------------------------------------------------
// RAII handles
// ---------------------------------------------------------------------------
//
// Each owns exactly one border handle and is not copyable.

class Txn {
public:
    explicit Txn(loom_store *store) : txn(0) {
        loom_txn_begin(store, &txn);
    }

    ~Txn() {
        if (txn != 0) {
            loom_txn_release(txn);
        }
    }

    bool ok() const {
        return txn != 0;
    }

    bool commit() {
        return txn != 0 && loom_txn_commit(txn) == LOOM_OK;
    }

    loom_txn *get() {
        return txn;
    }

private:
    Txn(const Txn &);
    Txn &operator=(const Txn &);

    loom_txn *txn;
};

class Outcome {
public:
    Outcome() {
        memset(&raw, 0, sizeof(raw));
        raw.status = LOOM_OUTCOME_UNAVAILABLE;
    }

    ~Outcome() {
        loom_outcome_free(&raw);
    }

    loom_outcome raw;

private:
    Outcome(const Outcome &);
    Outcome &operator=(const Outcome &);
};

class IdListBox {
public:
    IdListBox() {
        list.ids   = 0;
        list.count = 0;
    }

    ~IdListBox() {
        loom_id_list_free(list);
    }

    loom_id_list *out() {
        loom_id_list_free(list);
        list.ids   = 0;
        list.count = 0;
        return &list;
    }

    const loom_id_list *get() const {
        return &list;
    }

    Size size() const {
        return list.count;
    }

    Id at(Size index) const {
        Id id;
        if (index < list.count) {
            memcpy(id.bytes, list.ids + index * LOOM_ID_SIZE, LOOM_ID_SIZE);
        }
        return id;
    }

    bool contains(const Id &id) const {
        for (Size i = 0; i < list.count; ++i) {
            if (memcmp(list.ids + i * LOOM_ID_SIZE, id.bytes, LOOM_ID_SIZE) == 0) {
                return true;
            }
        }
        return false;
    }

private:
    IdListBox(const IdListBox &);
    IdListBox &operator=(const IdListBox &);

    loom_id_list list;
};

class InputInfo {
public:
    InputInfo() {
        memset(&raw, 0, sizeof(raw));
    }

    ~InputInfo() {
        loom_input_info_free(&raw);
    }

    void reset() {
        loom_input_info_free(&raw);
        memset(&raw, 0, sizeof(raw));
    }

    String name() const {
        return buffer_text(raw.name);
    }

    String source_output() const {
        return buffer_text(raw.source_output);
    }

    Id source() const {
        Id id;
        memcpy(id.bytes, raw.source, LOOM_ID_SIZE);
        return id;
    }

    loom_input_info raw;

private:
    static String buffer_text(const loom_buffer &buffer) {
        return buffer.data == 0
                   ? String()
                   : String(reinterpret_cast<const char *>(buffer.data), buffer.size);
    }

    InputInfo(const InputInfo &);
    InputInfo &operator=(const InputInfo &);
};

class OutputInfo {
public:
    OutputInfo() {
        memset(&raw, 0, sizeof(raw));
    }

    ~OutputInfo() {
        loom_output_info_free(&raw);
    }

    void reset() {
        loom_output_info_free(&raw);
        memset(&raw, 0, sizeof(raw));
    }

    String name() const {
        return raw.name.data == 0
                   ? String()
                   : String(reinterpret_cast<const char *>(raw.name.data), raw.name.size);
    }

    loom_output_info raw;

private:
    OutputInfo(const OutputInfo &);
    OutputInfo &operator=(const OutputInfo &);
};

} // namespace lucia
