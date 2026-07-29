#pragma once

#include <ctype.h>
#include <string.h>

#include "engine.h"

namespace lucia {

// Persisted evaluator names the terminal can assign with eval.  Outputs
// the computation does not emit fall back to their stored sources behind
// the border, so the name port needs no handling here.
inline const char EVALUATOR_NAMES[] = "concat sum upper";

inline bool known_evaluator(const String &name) {
    return name == "concat" || name == "sum" || name == "upper";
}

// ---------------------------------------------------------------------------
// Terminal evaluators
// ---------------------------------------------------------------------------
//
// Pure C-callback computations behind loom_registry_put.  Each reads its
// inputs by port name and emits one "value" output; a missing or
// unavailable input emits unavailable rather than an error.

inline const loom_outcome *find_eval_input(const loom_eval_input *inputs, Size count,
                                           const char *name) {
    for (Size i = 0; i < count; ++i) {
        if (strcmp(inputs[i].name, name) == 0) {
            return inputs[i].outcome;
        }
    }
    return 0;
}

inline bool available_text(const loom_outcome *outcome, String *text) {
    if (outcome == 0 || outcome->status != LOOM_OUTCOME_AVAILABLE ||
        outcome->value.tag != LOOM_VALUE_TEXT) {
        return false;
    }
    *text = outcome->value.data.data == 0
                ? String()
                : String(reinterpret_cast<const char *>(outcome->value.data.data),
                         outcome->value.data.size);
    return true;
}

inline void emit_unavailable(loom_emit_fn emit, void *sink) {
    loom_outcome outcome;
    memset(&outcome, 0, sizeof(outcome));
    outcome.status = LOOM_OUTCOME_UNAVAILABLE;
    emit(sink, "value", &outcome);
}

inline void emit_text(loom_emit_fn emit, void *sink, const String &text) {
    loom_outcome outcome;
    memset(&outcome, 0, sizeof(outcome));
    outcome.status    = LOOM_OUTCOME_AVAILABLE;
    outcome.value.tag = LOOM_VALUE_TEXT;
    outcome.value.data.data =
        const_cast<Byte *>(reinterpret_cast<const Byte *>(text.data()));
    outcome.value.data.size = text.size();
    emit(sink, "value", &outcome);
}

// concat: left text + right text -> value text.
inline void concat_evaluator(void *, const loom_eval_input *inputs, Size count,
                             loom_emit_fn emit, void *sink) {
    String left;
    String right;
    if (!available_text(find_eval_input(inputs, count, "left"), &left) ||
        !available_text(find_eval_input(inputs, count, "right"), &right)) {
        emit_unavailable(emit, sink);
        return;
    }
    emit_text(emit, sink, left + right);
}

// sum: left int + right int -> value int.
inline void sum_evaluator(void *, const loom_eval_input *inputs, Size count,
                          loom_emit_fn emit, void *sink) {
    const loom_outcome *left  = find_eval_input(inputs, count, "left");
    const loom_outcome *right = find_eval_input(inputs, count, "right");
    if (left == 0 || right == 0 || left->status != LOOM_OUTCOME_AVAILABLE ||
        right->status != LOOM_OUTCOME_AVAILABLE || left->value.tag != LOOM_VALUE_INT ||
        right->value.tag != LOOM_VALUE_INT) {
        emit_unavailable(emit, sink);
        return;
    }
    loom_outcome outcome;
    memset(&outcome, 0, sizeof(outcome));
    outcome.status        = LOOM_OUTCOME_AVAILABLE;
    outcome.value.tag     = LOOM_VALUE_INT;
    outcome.value.integer = left->value.integer + right->value.integer;
    emit(sink, "value", &outcome);
}

// upper: text text -> value text, uppercased.
inline void upper_evaluator(void *, const loom_eval_input *inputs, Size count,
                            loom_emit_fn emit, void *sink) {
    String text;
    if (!available_text(find_eval_input(inputs, count, "text"), &text)) {
        emit_unavailable(emit, sink);
        return;
    }
    for (Size i = 0; i < text.size(); ++i) {
        text[i] = (char)toupper((unsigned char)text[i]);
    }
    emit_text(emit, sink, text);
}

// ---------------------------------------------------------------------------
// EvaluatorSet
// ---------------------------------------------------------------------------
//
// Owns the border registry with every terminal evaluator registered
// under its persisted name.
//
class EvaluatorSet {
public:
    EvaluatorSet() : registry(0) {
        loom_registry_new(&registry);
        loom_registry_put(registry, "concat", concat_evaluator, 0);
        loom_registry_put(registry, "sum", sum_evaluator, 0);
        loom_registry_put(registry, "upper", upper_evaluator, 0);
    }

    ~EvaluatorSet() {
        loom_registry_free(registry);
    }

    loom_registry *get() const {
        return registry;
    }

private:
    EvaluatorSet(const EvaluatorSet &);
    EvaluatorSet &operator=(const EvaluatorSet &);

    loom_registry *registry;
};

} // namespace lucia
