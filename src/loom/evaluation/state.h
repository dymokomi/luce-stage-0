#pragma once

#include "fabric/model/texel.h"
#include "fabric/persistence/store.h"
#include "loom/evaluation/spool.h"

namespace lucia {

extern const char STATE_EVALUATOR[];
extern const char DELAY_EVALUATOR[];

bool create_state(const TexelId &id, ValueType type, const Value &initial, Texel *texel);
bool create_delay(const TexelId &id, ValueType type, const Value &initial, Texel *texel);

// ---------------------------------------------------------------------------
// TemporalRuntime
// ---------------------------------------------------------------------------
//
// Advances one durable State or Delay from its bound next value.
//
class TemporalRuntime {
public:
    bool advance(Store *store, Spool *spool, const TexelId &id, String *error = 0);
};

} // namespace lucia
