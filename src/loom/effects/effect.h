#pragma once

#include "fabric/model/texel.h"
#include "fabric/persistence/store.h"
#include "loom/evaluation/spool.h"
#include "realm/authority/capability.h"

#include <map>

namespace lucia {

// ---------------------------------------------------------------------------
// EffectIntent
// ---------------------------------------------------------------------------
//
// Deterministic effect request data.  It deliberately carries no Fabric
// identity: request identity belongs to the effect protocol, not to a Texel.
//
class EffectIntent {
public:
    enum { REQUEST_ID_SIZE = 32 };

    EffectIntent();

    bool set(const Byte *request_id, const char *operation, const char *target,
             const Bytes &payload);

    const Byte   *request_id() const;
    const String &operation() const;
    const String &target() const;
    const Bytes  &payload() const;
    bool          valid() const;

private:
    Byte   id[REQUEST_ID_SIZE];
    String requested_operation;
    String requested_target;
    Bytes  request_payload;
};

bool encode_effect_intent(const EffectIntent &intent, Value *value);
bool decode_effect_intent(const Value &value, EffectIntent *intent);

// ---------------------------------------------------------------------------
// EffectObservation
// ---------------------------------------------------------------------------
//
// Durable result associated with one request id.  bytes contains the executor
// result on success and structured executor error data on failure.
//
class EffectObservation {
public:
    EffectObservation();

    bool set(const Byte *request_id, bool success, const Bytes &bytes);

    const Byte  *request_id() const;
    bool         success() const;
    const Bytes &bytes() const;
    bool         valid() const;

private:
    Byte  id[EffectIntent::REQUEST_ID_SIZE];
    bool  succeeded;
    Bytes observation_bytes;
};

bool encode_effect_observation(const EffectObservation &observation, Value *value);
bool decode_effect_observation(const Value &value, EffectObservation *observation);

// ---------------------------------------------------------------------------
// EffectExecutor
// ---------------------------------------------------------------------------
//
// Executors are trusted and non-owning.  perform must be idempotent by
// intent.request_id(): retrying the same request must return the same logical
// observation without repeating the outside-world action.  Arbitrary
// exactly-once effects are otherwise impossible because Store commit and the
// outside world cannot be made crash-atomic.
//
class EffectExecutor {
public:
    virtual ~EffectExecutor();
    virtual bool perform(const EffectIntent &intent, EffectObservation *observation) = 0;
};

typedef std::map<String, EffectExecutor *> EffectExecutorTable;

class EffectExecutorRegistry {
public:
    bool put(const char *operation, EffectExecutor *executor);
    bool get(const char *operation, EffectExecutor **executor) const;

private:
    EffectExecutorTable executors;
};

enum EffectBoundaryCode {
    EFFECT_PERFORMED = 0,
    EFFECT_REPLAYED,
    EFFECT_INVALID_ARGUMENT,
    EFFECT_MISSING_EFFECT,
    EFFECT_MALFORMED_EFFECT,
    EFFECT_MISSING_INTENT,
    EFFECT_MALFORMED_INTENT,
    EFFECT_MISSING_CAPABILITY,
    EFFECT_MALFORMED_CAPABILITY,
    EFFECT_CAPABILITY_DENIED,
    EFFECT_MISSING_EXECUTOR,
    EFFECT_EXECUTOR_FAILED,
    EFFECT_INVALID_OBSERVATION,
    EFFECT_STORE_FAILED,
    EFFECT_MALFORMED_RECEIPT
};

// ---------------------------------------------------------------------------
// EffectBoundaryResult
// ---------------------------------------------------------------------------
//
// A structured boundary result.  observation is present only for performed or
// replayed effects; no-capability and malformed requests perform nothing.
//
class EffectBoundaryResult {
public:
    EffectBoundaryResult();

    EffectBoundaryCode       code() const;
    const String            &message() const;
    bool                     has_observation() const;
    const EffectObservation &observation() const;
    bool                     succeeded() const;

private:
    friend class EffectBoundary;

    EffectBoundaryCode boundary_code;
    String             boundary_message;
    bool               observation_present;
    EffectObservation  effect_observation;
};

// Produces the stable receipt identity for a request id.
bool effect_observation_id(const Byte *request_id, TexelId *id);

// Helpers which enforce the port shapes consumed by EffectBoundary.
bool make_effect_texel(const TexelId &id, const EffectIntent &intent, Texel *texel);
bool make_capability_texel(const TexelId &id, const Capability &capability, Texel *texel);

// ---------------------------------------------------------------------------
// EffectBoundary
// ---------------------------------------------------------------------------
//
// The only object here with Store and executor access.  Evaluators remain
// pure: they receive neither.  Store, Spool, Authority, and registry are
// non-owning and must outlive this boundary.
//
class EffectBoundary {
public:
    EffectBoundary(Store *store, Spool *spool, const Authority *authority,
                   const EffectExecutorRegistry *registry);

    EffectBoundaryResult perform(const TexelId &effect);

private:
    EffectBoundaryResult error(EffectBoundaryCode code, const char *message) const;
    EffectBoundaryResult receipt(const EffectObservation &observation,
                                 EffectBoundaryCode       code) const;

    Store                        *store;
    Spool                        *spool;
    const Authority              *authority;
    const EffectExecutorRegistry *registry;
};

} // namespace lucia
