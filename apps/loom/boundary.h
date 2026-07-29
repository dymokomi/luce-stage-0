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
// Store's volatile observe path, bumping revisions and the logical
// generation without touching the volume.  Nothing downstream recomputes
// until something demands it: push invalidates, pull evaluates.  An
// observation becomes durable only when a later commit snapshots it.
//
// keyboard offers line (text, the last line typed) and count (int).  mouse
// offers x, y (real) and button (int); it cannot fire while the terminal
// reads whole lines from a tty, and waits for raw-mode input to arrive.
//
inline const char KEYBOARD_NAME[] = "keyboard";
inline const char MOUSE_NAME[]    = "mouse";

// Find a texel by exact name without reporting; boundary lookups are quiet.
inline bool find_named(const Store *store, const String &name, TexelId *id) {
    for (Size i = 0; i < store->size(); ++i) {
        Texel texel;
        if (!store->at(i, &texel)) {
            return false;
        }
        String found;
        if (texel_name(texel, &found) && found == name) {
            *id = texel.id();
            return true;
        }
    }
    return false;
}

inline Texel make_boundary(const char *name) {
    TexelId id;
    id.generate();
    Texel texel(id);
    set_name(&texel, name);
    return texel;
}

// Create the boundary texels missing from this Fabric, in one commit.
inline bool ensure_boundary(Store *store) {
    Transaction transaction;
    bool        began = false;
    TexelId     ignored;

    if (!find_named(store, KEYBOARD_NAME, &ignored)) {
        Texel      keyboard = make_boundary(KEYBOARD_NAME);
        OutputPort line("line", VALUE_TEXT);
        OutputPort count("count", VALUE_INT);
        line.set_source(Value(String()));
        count.set_source(Value((S64)0));
        keyboard.put_output(line);
        keyboard.put_output(count);
        if (!store->begin(&transaction)) {
            return false;
        }
        began = true;
        if (!transaction.put(keyboard)) {
            return false;
        }
    }
    if (!find_named(store, MOUSE_NAME, &ignored)) {
        Texel      mouse = make_boundary(MOUSE_NAME);
        OutputPort x("x", VALUE_REAL);
        OutputPort y("y", VALUE_REAL);
        OutputPort button("button", VALUE_INT);
        x.set_source(Value(0.0));
        y.set_source(Value(0.0));
        button.set_source(Value((S64)0));
        mouse.put_output(x);
        mouse.put_output(y);
        mouse.put_output(button);
        if (!began && !store->begin(&transaction)) {
            return false;
        }
        began = true;
        if (!transaction.put(mouse)) {
            return false;
        }
    }
    return began ? transaction.commit() : true;
}

// Record one keyboard interaction: the line just typed, and one more count.
inline bool observe_keyboard(Store *store, const String &line) {
    TexelId id;
    Texel   keyboard;
    if (!find_named(store, KEYBOARD_NAME, &id) || !store->get(id, &keyboard)) {
        return false;
    }
    OutputPort count;
    if (!keyboard.get_output("count", &count)) {
        return false;
    }
    const S64 counted = count.has_source() ? count.source().integer() : 0;
    return store->observe(id, "line", Value(line)) &&
           store->observe(id, "count", Value(counted + 1));
}

} // namespace lucia
