#include "projection/file/projection_manifest.h"

namespace lucia {

namespace {

bool valid_filename(const String &filename) {
    if (filename.empty() || filename[0] == '/' || filename[filename.size() - 1] == '/') {
        return false;
    }

    Size first = 0;
    while (first < filename.size()) {
        const Size   slash = filename.find('/', first);
        const Size   last  = slash == String::npos ? filename.size() : slash;
        const String part  = filename.substr(first, last - first);
        if (part.empty() || part == "." || part == ".." ||
            part.find('\\') != String::npos) {
            return false;
        }
        first = last + 1;
    }
    return true;
}

} // namespace

ProjectionEntry::ProjectionEntry() : value_type(VALUE_NONE) {}

ProjectionEntry::ProjectionEntry(const TexelId &texel, const char *output, ValueType type,
                                 const char *filename)
    : texel_id(texel), output_name(output != 0 ? output : ""), value_type(type),
      relative_filename(filename != 0 ? filename : "") {}

const TexelId &ProjectionEntry::texel() const {
    return texel_id;
}

const String &ProjectionEntry::output() const {
    return output_name;
}

ValueType ProjectionEntry::type() const {
    return value_type;
}

const String &ProjectionEntry::filename() const {
    return relative_filename;
}

bool ProjectionEntry::valid() const {
    return !texel_id.is_unset() && !output_name.empty() &&
           (value_type == VALUE_TEXT || value_type == VALUE_BLOB) &&
           valid_filename(relative_filename);
}

Size ProjectionManifest::size() const {
    return entries.size();
}

bool ProjectionManifest::at(Size index, ProjectionEntry *entry) const {
    if (entry == 0 || index >= entries.size()) {
        return false;
    }
    *entry = entries[index];
    return true;
}

bool ProjectionManifest::put(const ProjectionEntry &entry) {
    if (!entry.valid()) {
        return false;
    }
    for (Size i = 0; i < entries.size(); ++i) {
        if (entries[i].filename() == entry.filename() ||
            (entries[i].texel().equals(entry.texel()) &&
             entries[i].output() == entry.output())) {
            return false;
        }
    }
    entries.push_back(entry);
    return true;
}

bool ProjectionManifest::has_file(const String &filename) const {
    for (Size i = 0; i < entries.size(); ++i) {
        if (entries[i].filename() == filename) {
            return true;
        }
    }
    return false;
}

bool ProjectionManifest::has_directory(const String &dirname) const {
    const String prefix = dirname + "/";
    for (Size i = 0; i < entries.size(); ++i) {
        if (entries[i].filename().compare(0, prefix.size(), prefix) == 0) {
            return true;
        }
    }
    return false;
}

} // namespace lucia
