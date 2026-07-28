#include "state.h"

namespace lucia {

const char STATE_EVALUATOR[] = "loom.state";
const char DELAY_EVALUATOR[] = "loom.delay";

namespace {

bool fail(String* error, const char* message)
{
  if (error != 0) {
    *error = message;
  }
  return false;
}

bool temporal_evaluator(const String& evaluator)
{
  return evaluator == STATE_EVALUATOR || evaluator == DELAY_EVALUATOR;
}

bool temporal_shape(const Texel& texel, InputPort* next, OutputPort* value)
{
  if (!temporal_evaluator(texel.evaluator()) ||
      texel.input_size() != 1 || texel.output_size() != 1 ||
      !texel.get_input("next", next) ||
      !texel.get_output("value", value)) {
    return false;
  }
  return next->type() == value->type() &&
         value->has_source() &&
         value->source().type() == value->type();
}

bool create_temporal(const TexelId& id, const char* evaluator,
                     ValueType type, const Value& initial, Texel* texel)
{
  if (texel == 0 || id.is_unset() ||
      type == VALUE_NONE || initial.type() != type) {
    return false;
  }

  Texel created(id);
  OutputPort value("value", type);
  if (!created.set_evaluator(evaluator) ||
      !created.put_input(InputPort("next", type)) ||
      !value.set_source(initial) ||
      !created.put_output(value)) {
    return false;
  }
  *texel = created;
  return true;
}

}  // namespace

bool create_state(const TexelId& id, ValueType type, const Value& initial,
                  Texel* texel)
{
  return create_temporal(id, STATE_EVALUATOR, type, initial, texel);
}

bool create_delay(const TexelId& id, ValueType type, const Value& initial,
                  Texel* texel)
{
  return create_temporal(id, DELAY_EVALUATOR, type, initial, texel);
}

bool TemporalRuntime::advance(Store* store, Spool* spool, const TexelId& id,
                              String* error)
{
  if (error != 0) {
    error->clear();
  }
  if (store == 0) {
    return fail(error, "temporal advance: no store");
  }
  if (spool == 0) {
    return fail(error, "temporal advance: no spool");
  }
  if (!store->is_open()) {
    return fail(error, "temporal advance: store is not open");
  }
  if (id.is_unset()) {
    return fail(error, "temporal advance: unset texel id");
  }

  Texel temporal;
  InputPort next;
  OutputPort value;
  if (!store->get(id, &temporal)) {
    return fail(error, "temporal advance: missing texel");
  }
  if (!temporal_shape(temporal, &next, &value)) {
    return fail(error, "temporal advance: invalid State or Delay");
  }
  if (!next.has_binding()) {
    return fail(error, "temporal advance: next is unbound");
  }

  const Fiber& binding = next.binding();
  ValueOutcome outcome;
  if (!spool->demand(binding.source(), binding.output().c_str(), &outcome)) {
    return fail(error, "temporal advance: demand failed");
  }
  if (outcome.status() == VALUE_ERROR) {
    if (error != 0) {
      *error = "temporal advance: " + outcome.message();
    }
    return false;
  }
  if (outcome.status() != VALUE_AVAILABLE) {
    return fail(error, "temporal advance: next is unavailable");
  }
  if (outcome.value().type() != value.type()) {
    return fail(error, "temporal advance: next type mismatch");
  }

  Transaction transaction;
  if (!store->begin(&transaction)) {
    return fail(error, "temporal advance: could not begin transaction");
  }

  Texel changed;
  InputPort current_next;
  OutputPort current_value;
  if (!transaction.get(id, &changed) ||
      !temporal_shape(changed, &current_next, &current_value) ||
      changed.revision() != temporal.revision() ||
      !current_value.set_source(outcome.value()) ||
      !changed.put_output(current_value) ||
      !transaction.put(changed)) {
    transaction.abort();
    return fail(error, "temporal advance: could not update value");
  }
  if (!transaction.commit()) {
    transaction.abort();
    return fail(error, "temporal advance: commit failed");
  }
  return true;
}

}  // namespace lucia
