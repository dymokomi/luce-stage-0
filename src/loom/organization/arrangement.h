#pragma once

#include "fabric/model/texel.h"
#include "fabric/model/texel_id.h"
#include "fabric/persistence/store.h"

namespace lucia {

// ---------------------------------------------------------------------------
// ArrangementEntry
// ---------------------------------------------------------------------------
//
// A context-local name and the stable identity it references.
//
struct ArrangementEntry {
  String  name;
  TexelId texel;
};

typedef std::vector<ArrangementEntry> ArrangementEntries;

enum {
  ARRANGEMENT_MAX_NAME_SIZE    = 255,
  ARRANGEMENT_MAX_ENTRIES      = 4096,
  ARRANGEMENT_MAX_CONTENT_SIZE = 1024 * 1024
};

// Creates an ordinary Texel with empty arrangement content.
bool create_arrangement(const TexelId &id, Texel *arrangement);

// Strictly decodes all arrangement content.
bool inspect_arrangement(const Texel &arrangement, ArrangementEntries *entries);

// Also requires every referenced Texel to exist in the Store.
bool validate_arrangement(const Texel &arrangement, const Store &store);

// Mutations preserve referenced TexelIds and only rewrite arrangement content.
// Persist the changed Texel with Transaction::put.
bool arrangement_add(Texel *arrangement, const char *name, const TexelId &texel);
bool arrangement_rename(Texel *arrangement, const char *name, const char *replacement);
bool arrangement_reorder(Texel *arrangement, const char *name, Size index);
bool arrangement_remove(Texel *arrangement, const char *name);

} // namespace lucia
