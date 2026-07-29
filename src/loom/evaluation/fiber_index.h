#pragma once

#include "fabric/persistence/store.h"

namespace lucia {

typedef std::map<TexelId, TexelIdSet> EdgeTable;

// ---------------------------------------------------------------------------
// FiberIndex
// ---------------------------------------------------------------------------
//
// Disposable reverse index from source texels to the texels whose Input
// Ports consume them.  An Output Port owns no durable consumer list
// (LOOM.md); this is the machinery Loom builds instead.  Rebuilt from any
// Store snapshot, kept current from ChangeSets, and deliberately
// texel-granular: any change to a texel dirties all of its consumers.
// Over-marking costs a revalidation; under-marking would be a bug.
//
class FiberIndex {
public:
    bool build(const Store *store);
    bool apply(const Store *store, const TexelIdList &changed);

    // Expand changed texels to every transitive consumer, changed included.
    bool downstream(const TexelIdList &changed, TexelIdSet *dirty) const;

    Size size() const;

private:
    void forget(const TexelId &consumer);
    void learn(const Texel &texel);

    EdgeTable consumers; // source -> texels bound to one of its outputs
    EdgeTable sources;   // consumer -> sources it is bound to
};

} // namespace lucia
