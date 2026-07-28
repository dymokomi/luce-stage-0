#pragma once

#include "loom/evaluation/spool.h"

namespace lucia {

extern const char *PROSE_VIEW_EVALUATOR;
extern const char *TABLE_VIEW_EVALUATOR;
extern const char *VIEW_INTERFACE_OUTPUT;

// ---------------------------------------------------------------------------
// ProseViewEvaluator
// ---------------------------------------------------------------------------
//
// Pure text renderer for the ordered text inputs of a View Texel.
//
class ProseViewEvaluator : public Evaluator {
public:
  void evaluate(const Texel &texel, const ValueOutcomeMap &inputs,
                ValueOutcomeMap *outputs) override;
};

// ---------------------------------------------------------------------------
// TableViewEvaluator
// ---------------------------------------------------------------------------
//
// Pure ASCII table renderer for the ordered text inputs of a View Texel.
//
class TableViewEvaluator : public Evaluator {
public:
  void evaluate(const Texel &texel, const ValueOutcomeMap &inputs,
                ValueOutcomeMap *outputs) override;
};

bool make_prose_view(const TexelId &id, const Strings &inputs, Texel *view);
bool make_table_view(const TexelId &id, const Strings &inputs, Texel *view);

} // namespace lucia
