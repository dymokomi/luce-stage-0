#pragma once

#include "key.h"
#include "types.h"

namespace lucia {

// ---------------------------------------------------------------------------
// Seal
// ---------------------------------------------------------------------------
//
// AEAD lock/unlock of byte payloads (at-rest and on the wire).
// Development implementation until Monocypher lands — authenticates with the
// key (wrong key or tamper fails) but is not production crypto.
//
bool seal  (const Byte* plaintext,  Size plain_size,
            const Byte* key,        Size key_size,
            Bytes* ciphertext);

bool unseal(const Byte* ciphertext, Size cipher_size,
            const Byte* key,        Size key_size,
            Bytes* plaintext);

bool sign  (const Byte* message, Size message_size,
            const KeyPair& keys,
            Byte signature[SIGNATURE_SIZE]);

bool verify(const Byte* message, Size message_size,
            const PublicKey& public_key,
            const Byte signature[SIGNATURE_SIZE]);

}  // namespace lucia
