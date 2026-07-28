#pragma once

#include "types.h"

namespace lucia {

// ---------------------------------------------------------------------------
// KeyPair / PublicKey
// ---------------------------------------------------------------------------
//
// Scaffold for Loom crypto: signing and sealing.
// Encryption is confidentiality (disk and wire), never revocation.
// See planning/LOOM.md.
//
// Implementations land later (Monocypher).  These types only fix the shape.
//

enum { KEY_SIZE       = 32 };
enum { SIGNATURE_SIZE = 64 };

class PublicKey {
public:
  PublicKey();

  bool is_unset() const;
  bool equals(const PublicKey& other) const;
  const Byte* bytes() const;
  void set_bytes(const Byte* data);

private:
  Byte key_bytes[KEY_SIZE];
};

class KeyPair {
public:
  KeyPair();

  const PublicKey& public_key() const;
  const Byte*      secret_bytes() const;

  // Fills a development key pair.  Real entropy arrives with platform +
  // Monocypher.
  bool generate();

  // Install a 32-byte secret and derive the public half.
  bool set_secret(const Byte* secret);

private:
  PublicKey public_part;
  Byte      secret_bytes_data[KEY_SIZE];
};

}  // namespace lucia
