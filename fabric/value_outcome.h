#pragma once

#include "value.h"

namespace lucia {

enum ValueOutcomeStatus {
  VALUE_AVAILABLE   = 0,
  VALUE_UNAVAILABLE = 1,
  VALUE_ERROR       = 2
};

// ---------------------------------------------------------------------------
// ValueOutcome
// ---------------------------------------------------------------------------
//
// Explicit result of asking an evaluator for a Value.
//
class ValueOutcome {
public:
  ValueOutcome();

  static ValueOutcome available(const Value& value);
  static ValueOutcome unavailable();
  static ValueOutcome error(const char* message);

  ValueOutcomeStatus status() const;
  const Value&       value() const;
  const String&      message() const;

private:
  ValueOutcome(ValueOutcomeStatus status, const Value& value,
               const char* message);

  ValueOutcomeStatus outcome_status;
  Value              outcome_value;
  String             error_message;
};

}  // namespace lucia
