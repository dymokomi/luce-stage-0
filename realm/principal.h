#pragma once

#include "key.h"
#include "types.h"

namespace lucia {

// ---------------------------------------------------------------------------
// Principal
// ---------------------------------------------------------------------------
//
// An authenticated identity for sealing and signing fabric storage.
// Lives under realm/: grants and the Realm authority type come later.
//
class Principal {
public:
  Principal();

  bool create();

  // Install a principal from an existing 32-byte secret.
  bool set_secret(const Byte* secret);

  bool is_unset() const;

  const PublicKey& public_key() const;
  const KeyPair&   keys() const;

  // 32-byte key used by seal/unseal for this principal.
  const Byte* seal_key() const;

private:
  KeyPair key_pair;
};

}  // namespace lucia
