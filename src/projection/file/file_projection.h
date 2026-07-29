#pragma once

#include "fabric/persistence/store.h"
#include "projection/file/projection_manifest.h"

namespace lucia {

// ---------------------------------------------------------------------------
// ProjectionRecord
// ---------------------------------------------------------------------------
//
// In-memory state captured when one output was last synchronized.
//
class ProjectionRecord {
public:
  ProjectionRecord();
  ProjectionRecord(const ProjectionEntry &entry, U64 revision, const String &digest);

  const ProjectionEntry &entry() const;
  U64                    revision() const;
  const String          &digest() const;

private:
  ProjectionEntry projection_entry;
  U64             source_revision;
  String          content_digest;
};

typedef std::vector<ProjectionRecord> ProjectionRecords;

// ---------------------------------------------------------------------------
// FileProjection
// ---------------------------------------------------------------------------
//
// Controlled boundary between selected Fabric outputs and one host directory.
// The projection has no Fabric identity and owns no Store.
//
class FileProjection {
public:
  FileProjection();

  bool export_from(const Store &store, const ProjectionManifest &manifest,
                   const char *directory);
  bool import_changes(Store *store);

  bool is_exported() const;
  Size size() const;
  bool at(Size index, ProjectionRecord *record) const;

private:
  ProjectionManifest projection_manifest;
  ProjectionRecords  records;
  String             root_directory;
  bool               exported;
};

} // namespace lucia
