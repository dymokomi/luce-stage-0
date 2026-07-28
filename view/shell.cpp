#include "shell.h"

namespace lucia {

Shell::Shell(Store* fabric_store)
    : store(fabric_store),
      spool(fabric_store, &registry),
      has_focus(false),
      focus_index(0),
      ready(false)
{
  ready = registry.put(PROSE_VIEW_EVALUATOR, &prose) &&
          registry.put(TABLE_VIEW_EVALUATOR, &table);
}

bool Shell::is_ready() const
{
  return ready && store != 0 && store->is_open();
}

bool Shell::add(const TexelId& view, const char* accessibility_label)
{
  if (!is_ready() || view.is_unset() || accessibility_label == 0 ||
      accessibility_label[0] == '\0') {
    return false;
  }

  Texel texel;
  if (!store->get(view, &texel) ||
      (texel.evaluator() != PROSE_VIEW_EVALUATOR &&
       texel.evaluator() != TABLE_VIEW_EVALUATOR)) {
    return false;
  }

  Surface surface;
  surface.view = view;
  surface.label = accessibility_label;
  surfaces.push_back(surface);
  return true;
}

Size Shell::size() const
{
  return surfaces.size();
}

bool Shell::focus(Size index)
{
  if (index >= surfaces.size()) {
    return false;
  }
  focus_index = index;
  has_focus = true;
  return true;
}

bool Shell::focused(Size* index) const
{
  if (index == 0 || !has_focus) {
    return false;
  }
  *index = focus_index;
  return true;
}

bool Shell::interface(const TexelId& view, String* text)
{
  if (!is_ready() || text == 0) {
    return false;
  }

  ValueOutcome outcome;
  if (!spool.demand(view, VIEW_INTERFACE_OUTPUT, &outcome) ||
      outcome.status() != VALUE_AVAILABLE ||
      outcome.value().type() != VALUE_TEXT) {
    return false;
  }
  *text = outcome.value().text();
  return true;
}

bool Shell::compose(String* frame)
{
  if (!is_ready() || frame == 0) {
    return false;
  }

  String rendered;
  for (Size i = 0; i < surfaces.size(); ++i) {
    String content;
    if (!interface(surfaces[i].view, &content)) {
      return false;
    }
    if (!rendered.empty()) {
      rendered += "\n";
    }
    rendered += "[" + surfaces[i].label + "]\n" + content + "\n";
  }
  *frame = rendered;
  return true;
}

bool Shell::accessibility_labels(Strings* labels) const
{
  if (labels == 0) {
    return false;
  }
  labels->clear();
  for (Size i = 0; i < surfaces.size(); ++i) {
    labels->push_back(surfaces[i].label);
  }
  return true;
}

bool Shell::edit(const TexelId& source, const char* output_name,
                 const char* text)
{
  if (!is_ready() || !has_focus || source.is_unset() ||
      output_name == 0 || output_name[0] == '\0' || text == 0) {
    return false;
  }

  Transaction transaction;
  Texel texel;
  OutputPort output;
  if (!store->begin(&transaction)) {
    return false;
  }
  if (!transaction.get(source, &texel) || !texel.evaluator().empty() ||
      !texel.get_output(output_name, &output) ||
      output.type() != VALUE_TEXT ||
      !output.set_source(Value(text)) ||
      !texel.put_output(output) ||
      !transaction.put(texel)) {
    transaction.abort();
    return false;
  }
  if (!transaction.commit()) {
    return false;
  }
  return true;
}

}  // namespace lucia
