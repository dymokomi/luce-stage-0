#include "key.h"

#include <string.h>

namespace lucia {

namespace {

U64 mix64(U64 value)
{
  value ^= value >> 30;
  value *= 0xbf58476d1ce4e5b9ULL;
  value ^= value >> 27;
  value *= 0x94d049bb133111ebULL;
  value ^= value >> 31;
  return value;
}

}  // namespace

PublicKey::PublicKey()
{
  memset(key_bytes, 0, KEY_SIZE);
}

bool PublicKey::is_unset() const
{
  for (Size i = 0; i < KEY_SIZE; ++i) {
    if (key_bytes[i] != 0) {
      return false;
    }
  }
  return true;
}

const Byte* PublicKey::bytes() const
{
  return key_bytes;
}

void PublicKey::set_bytes(const Byte* data)
{
  if (data == 0) {
    memset(key_bytes, 0, KEY_SIZE);
    return;
  }
  memcpy(key_bytes, data, KEY_SIZE);
}

bool PublicKey::equals(const PublicKey& other) const
{
  return memcmp(key_bytes, other.key_bytes, KEY_SIZE) == 0;
}

KeyPair::KeyPair()
{
  memset(secret_bytes_data, 0, KEY_SIZE);
}

const PublicKey& KeyPair::public_key() const
{
  return public_part;
}

const Byte* KeyPair::secret_bytes() const
{
  return secret_bytes_data;
}

bool KeyPair::generate()
{
  // Development keys until platform entropy + Monocypher land.
  static U64 counter = 1;
  U64 state = mix64(counter++);
  Byte secret[KEY_SIZE];
  for (Size i = 0; i < KEY_SIZE; ++i) {
    state = mix64(state + (U64)i + 0x9e3779b97f4a7c15ULL);
    secret[i] = (Byte)(state & 0xff);
  }
  return set_secret(secret);
}

bool KeyPair::set_secret(const Byte* secret)
{
  if (secret == 0) {
    return false;
  }

  memcpy(secret_bytes_data, secret, KEY_SIZE);

  Byte public_bytes[KEY_SIZE];
  for (Size i = 0; i < KEY_SIZE; ++i) {
    public_bytes[i] =
        (Byte)(secret_bytes_data[i] ^ secret_bytes_data[(i + 7) % KEY_SIZE] ^
               (Byte)(0xC3 + i));
  }
  public_part.set_bytes(public_bytes);
  return true;
}

}  // namespace lucia
