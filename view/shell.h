#pragma once

#include "evaluators.h"

#include <vector>

namespace lucia {

struct Surface {
  TexelId view;
  String  label;
};

typedef std::vector<Surface> SurfaceList;

// ---------------------------------------------------------------------------
// Shell
// ---------------------------------------------------------------------------
//
// Trusted, non-persistent presentation shell.  It owns evaluator instances and
// presentation state, but no Texels or other durable Fabric state.
//
class Shell {
public:
  explicit Shell(Store* store);

  bool is_ready() const;

  bool add(const TexelId& view, const char* accessibility_label);
  Size size() const;
  bool focus(Size index);
  bool focused(Size* index) const;

  bool interface(const TexelId& view, String* text);
  bool compose(String* frame);
  bool accessibility_labels(Strings* labels) const;

  bool edit(const TexelId& source, const char* output, const char* text);

private:
  Store*                 store;
  ProseViewEvaluator     prose;
  TableViewEvaluator     table;
  EvaluatorRegistry      registry;
  Spool                  spool;
  SurfaceList            surfaces;
  bool                   has_focus;
  Size                   focus_index;
  bool                   ready;
};

}  // namespace lucia
