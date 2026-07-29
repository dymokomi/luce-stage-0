#pragma once

#include <stdio.h>

#include "commands/common.h"

namespace lucia {

// ---------------------------------------------------------------------------
// Boundary texels
// ---------------------------------------------------------------------------
//
// The host enters the Fabric as observations (LOOM.md): a device pushes a
// new source value onto a boundary texel's Output Ports through the
// store's volatile observe path, bumping revisions and the logical
// generation without touching the volume.  Nothing downstream recomputes
// until something demands it: push invalidates, pull evaluates.  An
// observation becomes durable only when a later commit snapshots it.
//
// keyboard offers line (text, the last line typed) and count (int).
// mouse offers x, y (real) and button (int); it cannot fire while the
// terminal reads whole lines from a tty, and waits for raw-mode input.
//
inline const char KEYBOARD_NAME[] = "keyboard";
inline const char MOUSE_NAME[]    = "mouse";

// Find a texel by exact name without reporting; boundary lookups are quiet.
inline bool find_named(const loom_store *store, const String &name, Id *id) {
    const Size count = loom_store_count(store);
    for (Size i = 0; i < count; ++i) {
        Id candidate;
        if (loom_store_id_at(store, i, candidate.bytes) != LOOM_OK) {
            return false;
        }
        String found;
        if (texel_name(store, candidate, &found) && found == name) {
            *id = candidate;
            return true;
        }
    }
    return false;
}

// Create one boundary texel with typed, pre-set outputs.
inline bool make_boundary(loom_txn *txn, const char *name, const char *const *outputs,
                          const Byte *types, Size output_count) {
    Id id;
    if (loom_txn_create_texel(txn, id.bytes) != LOOM_OK || !set_name(txn, id, name)) {
        return false;
    }
    for (Size i = 0; i < output_count; ++i) {
        if (loom_txn_put_output(txn, id.bytes, outputs[i], types[i]) != LOOM_OK) {
            return false;
        }
        ValueBox initial;
        switch (types[i]) {
        case LOOM_VALUE_TEXT:
            initial.set_text("");
            break;
        case LOOM_VALUE_INT:
            initial.set_int(0);
            break;
        default:
            initial.set_real(0.0);
            break;
        }
        if (loom_txn_set_source(txn, id.bytes, outputs[i], &initial.raw) != LOOM_OK) {
            return false;
        }
    }
    return true;
}

// Create the boundary texels missing from this Fabric, in one commit.
inline bool ensure_boundary(loom_store *store) {
    Id         ignored;
    const bool keyboard = !find_named(store, KEYBOARD_NAME, &ignored);
    const bool mouse    = !find_named(store, MOUSE_NAME, &ignored);
    if (!keyboard && !mouse) {
        return true;
    }

    Txn txn(store);
    if (!txn.ok()) {
        return false;
    }
    if (keyboard) {
        const char *outputs[] = {"line", "count"};
        const Byte  types[]   = {LOOM_VALUE_TEXT, LOOM_VALUE_INT};
        if (!make_boundary(txn.get(), KEYBOARD_NAME, outputs, types, 2)) {
            return false;
        }
    }
    if (mouse) {
        const char *outputs[] = {"x", "y", "button"};
        const Byte  types[]   = {LOOM_VALUE_REAL, LOOM_VALUE_REAL, LOOM_VALUE_INT};
        if (!make_boundary(txn.get(), MOUSE_NAME, outputs, types, 3)) {
            return false;
        }
    }
    return txn.commit();
}

// Record one keyboard interaction: the line just typed, and one more count.
inline bool observe_keyboard(loom_store *store, const String &line) {
    Id id;
    if (!find_named(store, KEYBOARD_NAME, &id)) {
        return false;
    }
    OutputInfo count;
    S64        counted = 0;
    if (find_output(store, id, "count", &count) && count.raw.has_source &&
        count.raw.source.tag == LOOM_VALUE_INT) {
        counted = count.raw.source.integer;
    }

    ValueBox typed;
    typed.set_text(line);
    ValueBox next;
    next.set_int(counted + 1);
    return loom_store_observe(store, id.bytes, "line", &typed.raw) == LOOM_OK &&
           loom_store_observe(store, id.bytes, "count", &next.raw) == LOOM_OK;
}

} // namespace lucia
