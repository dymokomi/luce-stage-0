#include "loom/evaluation/fiber_index.h"

namespace lucia {

bool FiberIndex::build(const Store *store) {
    if (store == 0 || !store->is_open()) {
        return false;
    }
    consumers.clear();
    sources.clear();
    for (Size i = 0; i < store->size(); ++i) {
        Texel texel;
        if (!store->at(i, &texel)) {
            return false;
        }
        learn(texel);
    }
    return true;
}

bool FiberIndex::apply(const Store *store, const TexelIdList &changed) {
    if (store == 0 || !store->is_open()) {
        return false;
    }
    for (TexelIdList::const_iterator id = changed.begin(); id != changed.end(); ++id) {
        forget(*id);
        Texel texel;
        if (store->get(*id, &texel)) {
            learn(texel);
        } else {
            // A removed texel can have no remaining consumers; drop its row.
            consumers.erase(*id);
        }
    }
    return true;
}

bool FiberIndex::downstream(const TexelIdList &changed, TexelIdSet *dirty) const {
    if (dirty == 0) {
        return false;
    }
    dirty->clear();

    TexelIdList frontier = changed;
    for (Size next = 0; next < frontier.size(); ++next) {
        const TexelId id = frontier[next];
        if (!dirty->insert(id).second) {
            continue;
        }
        EdgeTable::const_iterator row = consumers.find(id);
        if (row == consumers.end()) {
            continue;
        }
        for (TexelIdSet::const_iterator consumer = row->second.begin();
             consumer != row->second.end(); ++consumer) {
            frontier.push_back(*consumer);
        }
    }
    return true;
}

Size FiberIndex::size() const {
    return sources.size();
}

void FiberIndex::forget(const TexelId &consumer) {
    EdgeTable::iterator known = sources.find(consumer);
    if (known == sources.end()) {
        return;
    }
    for (TexelIdSet::const_iterator source = known->second.begin();
         source != known->second.end(); ++source) {
        EdgeTable::iterator row = consumers.find(*source);
        if (row == consumers.end()) {
            continue;
        }
        row->second.erase(consumer);
        if (row->second.empty()) {
            consumers.erase(row);
        }
    }
    sources.erase(known);
}

void FiberIndex::learn(const Texel &texel) {
    for (Size i = 0; i < texel.input_size(); ++i) {
        InputPort input;
        if (!texel.input_at(i, &input) || !input.has_binding()) {
            continue;
        }
        consumers[input.binding().source()].insert(texel.id());
        sources[texel.id()].insert(input.binding().source());
    }
}

} // namespace lucia
