#include "evaluators.h"

namespace lucia {

void ConcatEvaluator::evaluate(const Texel &, const ValueOutcomeMap &inputs,
                               ValueOutcomeMap *outputs) {
  ValueOutcomeMap::const_iterator left  = inputs.find("left");
  ValueOutcomeMap::const_iterator right = inputs.find("right");
  if (left == inputs.end() || right == inputs.end() ||
      left->second.status() != VALUE_AVAILABLE ||
      right->second.status() != VALUE_AVAILABLE) {
    (*outputs)["value"] = ValueOutcome::unavailable();
    return;
  }
  (*outputs)["value"] = ValueOutcome::available(
      Value(left->second.value().text() + right->second.value().text()));
}

EvaluatorSet::EvaluatorSet() {
  table.put("concat", &concat);
}

const EvaluatorRegistry *EvaluatorSet::registry() const {
  return &table;
}

} // namespace lucia
