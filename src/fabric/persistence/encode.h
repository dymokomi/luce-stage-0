#pragma once

#include "base/types.h"
#include "fabric/model/blob_ref.h"
#include "fabric/model/texel.h"

namespace lucia {

struct BlobRecord {
  BlobRef reference;
  Bytes   bytes;
};

typedef std::vector<Texel>      Texels;
typedef std::vector<BlobRecord> BlobRecords;

// ---------------------------------------------------------------------------
// Snapshot binary encoding
// ---------------------------------------------------------------------------
//
// Versioned deterministic little-endian encoding for Texels and out-of-line
// blobs.  Decoding is strict and consumes the complete input.
//
bool encode_texel(const Texel &texel, Bytes *output);
bool decode_texel(const Byte *data, Size size, Texel *output);

bool encode_snapshot(const Texels &texels, const BlobRecords &blobs, Bytes *output);
bool decode_snapshot(const Byte *data, Size size, Texels *texels, BlobRecords *blobs);

// Checks graph bindings, types, blob references, and acyclicity.
bool validate_snapshot(const Texels &texels, const BlobRecords &blobs);

} // namespace lucia
