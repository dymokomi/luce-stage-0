#pragma once

#include <ctype.h>

#include "loom/evaluation/spool.h"

namespace lucia {

// Persisted evaluator names the terminal can assign with eval.
inline const char EVALUATOR_NAMES[] = "concat sum upper";

// ---------------------------------------------------------------------------
// Terminal evaluators
// ---------------------------------------------------------------------------
//
// Small pure computations, keyed by persisted name.  Each reads its inputs
// by port name and offers one "value" output; a missing or unavailable
// input makes the output unavailable rather than an error.
//
// The Spool requires an evaluator to produce every declared output, and
// terminal texels also carry constant source outputs (the name port).
// TerminalEvaluator passes those through so computed and constant outputs
// can live on one texel; subclasses implement compute for the rest.
//
class TerminalEvaluator : public Evaluator {
public:
    void evaluate(const Texel &texel, const ValueOutcomeMap &inputs,
                  ValueOutcomeMap *outputs) override {
        compute(texel, inputs, outputs);
        for (Size i = 0; i < texel.output_size(); ++i) {
            OutputPort port;
            if (!texel.output_at(i, &port) ||
                outputs->find(port.name()) != outputs->end()) {
                continue;
            }
            (*outputs)[port.name()] = port.has_source()
                                          ? ValueOutcome::available(port.source())
                                          : ValueOutcome::unavailable();
        }
    }

    virtual void compute(const Texel &texel, const ValueOutcomeMap &inputs,
                         ValueOutcomeMap *outputs) = 0;
};

// concat: left text + right text -> value text.
class ConcatEvaluator : public TerminalEvaluator {
public:
    void compute(const Texel &, const ValueOutcomeMap &inputs,
                 ValueOutcomeMap *outputs) override {
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
};

// sum: left int + right int -> value int.
class SumEvaluator : public TerminalEvaluator {
public:
    void compute(const Texel &, const ValueOutcomeMap &inputs,
                 ValueOutcomeMap *outputs) override {
        ValueOutcomeMap::const_iterator left  = inputs.find("left");
        ValueOutcomeMap::const_iterator right = inputs.find("right");
        if (left == inputs.end() || right == inputs.end() ||
            left->second.status() != VALUE_AVAILABLE ||
            right->second.status() != VALUE_AVAILABLE) {
            (*outputs)["value"] = ValueOutcome::unavailable();
            return;
        }
        (*outputs)["value"] = ValueOutcome::available(
            Value(left->second.value().integer() + right->second.value().integer()));
    }
};

// upper: text text -> value text, uppercased.
class UpperEvaluator : public TerminalEvaluator {
public:
    void compute(const Texel &, const ValueOutcomeMap &inputs,
                 ValueOutcomeMap *outputs) override {
        ValueOutcomeMap::const_iterator text = inputs.find("text");
        if (text == inputs.end() || text->second.status() != VALUE_AVAILABLE) {
            (*outputs)["value"] = ValueOutcome::unavailable();
            return;
        }
        String raised = text->second.value().text();
        for (Size i = 0; i < raised.size(); ++i) {
            raised[i] = (char)toupper((unsigned char)raised[i]);
        }
        (*outputs)["value"] = ValueOutcome::available(Value(raised));
    }
};

// ---------------------------------------------------------------------------
// EvaluatorSet
// ---------------------------------------------------------------------------
//
// Evaluators the terminal offers to the Spool, owned together and already
// registered under their persisted names.
//
class EvaluatorSet {
public:
    EvaluatorSet() {
        table.put("concat", &concat);
        table.put("sum", &sum);
        table.put("upper", &upper);
    }

    const EvaluatorRegistry *registry() const {
        return &table;
    }

private:
    EvaluatorSet(const EvaluatorSet &);
    EvaluatorSet &operator=(const EvaluatorSet &);

    ConcatEvaluator   concat;
    SumEvaluator      sum;
    UpperEvaluator    upper;
    EvaluatorRegistry table;
};

} // namespace lucia
