#pragma once

#include "loom/evaluation/spool.h"

namespace lucia {

// ---------------------------------------------------------------------------
// ConcatEvaluator
// ---------------------------------------------------------------------------
//
// Joins the text values arriving at "left" and "right" into "value".
//
class ConcatEvaluator : public Evaluator {
public:
  void evaluate(const Texel &texel, const ValueOutcomeMap &inputs,
                ValueOutcomeMap *outputs) override;
};

// ---------------------------------------------------------------------------
// EvaluatorSet
// ---------------------------------------------------------------------------
//
// Evaluators the loom application offers to the Spool, owned together and
// already registered under their persisted names.
//
class EvaluatorSet {
public:
  EvaluatorSet();

  const EvaluatorRegistry *registry() const;

private:
  EvaluatorSet(const EvaluatorSet &);
  EvaluatorSet &operator=(const EvaluatorSet &);

  ConcatEvaluator   concat;
  EvaluatorRegistry table;
};

} // namespace lucia
