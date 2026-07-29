#include "fabric/model/value_outcome.h"

namespace lucia {

ValueOutcome::ValueOutcome() : outcome_status(VALUE_UNAVAILABLE) {}

ValueOutcome::ValueOutcome(ValueOutcomeStatus status, const Value &value,
                           const char *message)
    : outcome_status(status), outcome_value(value),
      error_message(message != 0 ? message : "") {}

ValueOutcome ValueOutcome::available(const Value &value) {
  return ValueOutcome(VALUE_AVAILABLE, value, "");
}

ValueOutcome ValueOutcome::unavailable() {
  return ValueOutcome(VALUE_UNAVAILABLE, Value(), "");
}

ValueOutcome ValueOutcome::error(const char *message) {
  return ValueOutcome(VALUE_ERROR, Value(), message);
}

ValueOutcomeStatus ValueOutcome::status() const {
  return outcome_status;
}

const Value &ValueOutcome::value() const {
  return outcome_value;
}

const String &ValueOutcome::message() const {
  return error_message;
}

} // namespace lucia
