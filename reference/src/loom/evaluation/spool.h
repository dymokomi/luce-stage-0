#pragma once

#include "fabric/model/texel.h"
#include "fabric/model/value_outcome.h"
#include "fabric/persistence/store.h"

#include <map>
#include <set>
#include <vector>

namespace lucia {

typedef std::map<String, ValueOutcome> ValueOutcomeMap;

// ---------------------------------------------------------------------------
// Evaluator
// ---------------------------------------------------------------------------
//
// Pure computation supplied by Loom.  Input and output maps are ordered by
// persisted port name.  Evaluators are owned by their caller.
//
class Evaluator {
public:
    virtual ~Evaluator();

    virtual void evaluate(const Texel &texel, const ValueOutcomeMap &inputs,
                          ValueOutcomeMap *outputs) = 0;
};

typedef std::map<String, Evaluator *> EvaluatorTable;

// ---------------------------------------------------------------------------
// EvaluatorRegistry
// ---------------------------------------------------------------------------
//
// Non-owning lookup table from persisted evaluator names to implementations.
//
class EvaluatorRegistry {
public:
    bool put(const char *name, Evaluator *evaluator);
    bool get(const char *name, Evaluator **evaluator) const;
    Size size() const;

private:
    EvaluatorTable evaluators;
};

typedef std::vector<U64> RevisionList;

// ---------------------------------------------------------------------------
// Spool
// ---------------------------------------------------------------------------
//
// Disposable demand cache over one read-only Store and evaluator registry.
//
class Spool {
public:
    Spool(const Store *store, const EvaluatorRegistry *registry);

    bool demand(const TexelId &texel, const char *output, ValueOutcome *outcome);

    // Advance the cache across one reconcile step: records checked at
    // from_generation whose texel is not dirty are stamped as checked at
    // to_generation without touching the Store.  The dirty set must be a
    // conservative transitive closure of everything changed in between;
    // anything else revalidates lazily on its next demand.
    void advance(U64 from_generation, U64 to_generation, const TexelIdSet &dirty);

    void clear();
    Size cache_size() const;

private:
    struct Endpoint {
        TexelId texel;
        String  output;

        bool operator<(const Endpoint &other) const;
    };

    struct CachedOutput {
        ValueOutcome outcome;
        U64          effective_revision;
    };

    typedef std::map<String, CachedOutput> CachedOutputMap;

    struct SourceRecord {
        U64          checked_generation;
        U64          texel_revision;
        U64          output_revision;
        CachedOutput output;
    };

    struct ComputeRecord {
        U64             checked_generation;
        U64             texel_revision;
        RevisionList    input_revisions;
        CachedOutputMap outputs;
    };

    struct DemandResult {
        ValueOutcome outcome;
        U64          effective_revision;
    };

    typedef std::map<Endpoint, SourceRecord> SourceCache;
    typedef std::map<TexelId, ComputeRecord> ComputeCache;
    typedef std::set<TexelId>                ActiveTexels;

    DemandResult demand_internal(const TexelId &texel, const String &output,
                                 U64 generation);
    DemandResult demand_source(const Texel &texel, const OutputPort &output,
                               U64 generation);
    DemandResult demand_computed(const Texel &texel, const String &output, U64 generation);
    DemandResult evaluate(const Texel &texel, const String &output, U64 generation,
                          const ValueOutcomeMap &inputs, const RevisionList &revisions);
    DemandResult cache_error(const Texel &texel, const String &output, U64 generation,
                             const RevisionList &revisions, const String &message);

    bool next_effective_revision(U64 *revision);

    const Store             *store;
    const EvaluatorRegistry *registry;
    SourceCache              source_cache;
    ComputeCache             compute_cache;
    ActiveTexels             active;
    U64                      next_revision;
};

} // namespace lucia
