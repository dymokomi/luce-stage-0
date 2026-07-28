#pragma once

#include "base/types.h"
#include "fabric/model/texel_id.h"
#include "fabric/model/value.h"

namespace lucia {

// ---------------------------------------------------------------------------
// ProjectionEntry
// ---------------------------------------------------------------------------
//
// One Fabric output exposed as one relative host filename.
//
class ProjectionEntry {
public:
  ProjectionEntry();
  ProjectionEntry(const TexelId &texel, const char *output, ValueType type,
                  const char *filename);

  const TexelId &texel() const;
  const String  &output() const;
  ValueType      type() const;
  const String  &filename() const;

  bool valid() const;

private:
  TexelId   texel_id;
  String    output_name;
  ValueType value_type;
  String    relative_filename;
};

typedef std::vector<ProjectionEntry> ProjectionEntries;

// ---------------------------------------------------------------------------
// ProjectionManifest
// ---------------------------------------------------------------------------
//
// An explicit, identity-free map from Fabric outputs to host files.
//
class ProjectionManifest {
public:
  Size size() const;
  bool at(Size index, ProjectionEntry *entry) const;
  bool put(const ProjectionEntry &entry);

  bool has_file(const String &filename) const;
  bool has_directory(const String &dirname) const;

private:
  ProjectionEntries entries;
};

} // namespace lucia
