#include "view/runtime/evaluators.h"

namespace lucia {

const char *PROSE_VIEW_EVALUATOR  = "view.prose";
const char *TABLE_VIEW_EVALUATOR  = "view.table";
const char *VIEW_INTERFACE_OUTPUT = "interface";

namespace {

String flowing_text(const String &text) {
  String result;
  bool   spacing = false;
  for (Size i = 0; i < text.size(); ++i) {
    const char character = text[i];
    if (character == ' ' || character == '\t' || character == '\n' || character == '\r') {
      spacing = !result.empty();
      continue;
    }
    if (spacing) {
      result += ' ';
      spacing = false;
    }
    result += character;
  }
  return result;
}

bool available_text(const ValueOutcome &outcome, String *text) {
  if (text == 0 || outcome.status() != VALUE_AVAILABLE ||
      outcome.value().type() != VALUE_TEXT) {
    return false;
  }
  *text = flowing_text(outcome.value().text());
  return true;
}

String repeated(char character, Size size) {
  return String(size, character);
}

bool make_view(const TexelId &id, const char *evaluator, const Strings &inputs,
               Texel *view) {
  if (view == 0 || id.is_unset() || evaluator == 0) {
    return false;
  }

  Texel result(id);
  if (!result.set_evaluator(evaluator) ||
      !result.put_output(OutputPort(VIEW_INTERFACE_OUTPUT, VALUE_TEXT))) {
    return false;
  }
  for (Size i = 0; i < inputs.size(); ++i) {
    if (inputs[i].empty() || !result.put_input(InputPort(inputs[i].c_str(), VALUE_TEXT))) {
      return false;
    }
  }
  if (!result.valid()) {
    return false;
  }
  *view = result;
  return true;
}

} // namespace

void ProseViewEvaluator::evaluate(const Texel &, const ValueOutcomeMap &inputs,
                                  ValueOutcomeMap *outputs) {
  if (outputs == 0) {
    return;
  }

  String                          rendered;
  ValueOutcomeMap::const_iterator input = inputs.begin();
  for (; input != inputs.end(); ++input) {
    String text;
    if (!available_text(input->second, &text)) {
      (*outputs)[VIEW_INTERFACE_OUTPUT] = ValueOutcome::unavailable();
      return;
    }
    if (!rendered.empty()) {
      rendered += "\n\n";
    }
    rendered += input->first + ": " + text;
  }
  (*outputs)[VIEW_INTERFACE_OUTPUT] = ValueOutcome::available(Value(rendered));
}

void TableViewEvaluator::evaluate(const Texel &, const ValueOutcomeMap &inputs,
                                  ValueOutcomeMap *outputs) {
  if (outputs == 0) {
    return;
  }

  Size                            name_width  = 5;
  Size                            value_width = 5;
  ValueOutcomeMap::const_iterator input       = inputs.begin();
  for (; input != inputs.end(); ++input) {
    String text;
    if (!available_text(input->second, &text)) {
      (*outputs)[VIEW_INTERFACE_OUTPUT] = ValueOutcome::unavailable();
      return;
    }
    if (input->first.size() > name_width) {
      name_width = input->first.size();
    }
    if (text.size() > value_width) {
      value_width = text.size();
    }
  }

  const String border =
      "+" + repeated('-', name_width + 2) + "+" + repeated('-', value_width + 2) + "+\n";
  String rendered = border;
  rendered += "| Field" + repeated(' ', name_width - 5) + " | Value" +
              repeated(' ', value_width - 5) + " |\n";
  rendered += border;

  input = inputs.begin();
  for (; input != inputs.end(); ++input) {
    String text;
    available_text(input->second, &text);
    rendered += "| " + input->first + repeated(' ', name_width - input->first.size()) +
                " | " + text + repeated(' ', value_width - text.size()) + " |\n";
  }
  rendered += border.substr(0, border.size() - 1);

  (*outputs)[VIEW_INTERFACE_OUTPUT] = ValueOutcome::available(Value(rendered));
}

bool make_prose_view(const TexelId &id, const Strings &inputs, Texel *view) {
  return make_view(id, PROSE_VIEW_EVALUATOR, inputs, view);
}

bool make_table_view(const TexelId &id, const Strings &inputs, Texel *view) {
  return make_view(id, TABLE_VIEW_EVALUATOR, inputs, view);
}

} // namespace lucia
