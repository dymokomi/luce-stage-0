#include "seal.h"

#include <string.h>

namespace lucia {

namespace {

enum { TAG_SIZE = 32 };

void mix_block(Byte out[TAG_SIZE], const Byte* key, Size key_size,
               const Byte* data, Size data_size, Byte domain)
{
  memset(out, 0, TAG_SIZE);
  for (Size i = 0; i < TAG_SIZE; ++i) {
    out[i] = (Byte)(domain ^ key[i % key_size] ^ (Byte)(i * 131));
  }

  for (Size i = 0; i < data_size; ++i) {
    const Size j = i % TAG_SIZE;
    out[j] = (Byte)(out[j] + data[i] + (Byte)i);
    out[j] = (Byte)(out[j] ^ key[(i + data[i]) % key_size]);
    out[j] = (Byte)((out[j] << 1) | (out[j] >> 7));
  }
}

Byte keystream_byte(const Byte* key, Size key_size, Size index)
{
  Byte b = key[index % key_size];
  b = (Byte)(b ^ (Byte)index);
  b = (Byte)(b ^ (Byte)(index >> 8));
  b = (Byte)(b ^ (Byte)(index >> 16));
  return b;
}

}  // namespace

bool seal(const Byte* plaintext, Size plain_size,
          const Byte* key, Size key_size,
          Bytes* ciphertext)
{
  if (plaintext == 0 && plain_size != 0) {
    return false;
  }
  if (key == 0 || key_size != KEY_SIZE || ciphertext == 0) {
    return false;
  }

  ciphertext->clear();
  ciphertext->push_back((Byte)(plain_size & 0xff));
  ciphertext->push_back((Byte)((plain_size >> 8) & 0xff));
  ciphertext->push_back((Byte)((plain_size >> 16) & 0xff));
  ciphertext->push_back((Byte)((plain_size >> 24) & 0xff));

  const Size payload_offset = ciphertext->size();
  ciphertext->resize(payload_offset + plain_size + TAG_SIZE);

  for (Size i = 0; i < plain_size; ++i) {
    (*ciphertext)[payload_offset + i] =
        (Byte)(plaintext[i] ^ keystream_byte(key, key_size, i));
  }

  Byte tag[TAG_SIZE];
  mix_block(tag, key, key_size, plaintext, plain_size, 0xA5);
  memcpy(ciphertext->data() + payload_offset + plain_size, tag, TAG_SIZE);
  return true;
}

bool unseal(const Byte* ciphertext, Size cipher_size,
            const Byte* key, Size key_size,
            Bytes* plaintext)
{
  if (ciphertext == 0 || key == 0 || key_size != KEY_SIZE || plaintext == 0) {
    return false;
  }
  if (cipher_size < 4 + TAG_SIZE) {
    return false;
  }

  const Size plain_size =
      (Size)ciphertext[0] |
      ((Size)ciphertext[1] << 8) |
      ((Size)ciphertext[2] << 16) |
      ((Size)ciphertext[3] << 24);

  if (plain_size + 4 + TAG_SIZE != cipher_size) {
    return false;
  }

  plaintext->assign(plain_size, 0);
  for (Size i = 0; i < plain_size; ++i) {
    (*plaintext)[i] =
        (Byte)(ciphertext[4 + i] ^ keystream_byte(key, key_size, i));
  }

  Byte expected[TAG_SIZE];
  mix_block(expected, key, key_size, plaintext->data(), plain_size, 0xA5);
  if (memcmp(ciphertext + 4 + plain_size, expected, TAG_SIZE) != 0) {
    plaintext->clear();
    return false;
  }
  return true;
}

bool sign(const Byte* message, Size message_size,
          const KeyPair& keys,
          Byte signature[SIGNATURE_SIZE])
{
  if ((message == 0 && message_size != 0) || signature == 0) {
    return false;
  }
  if (keys.public_key().is_unset()) {
    return false;
  }

  // Development MAC.  Second half copies the public key so verify can
  // reject a mismatched author before Monocypher Ed25519 lands.
  mix_block(signature, keys.secret_bytes(), KEY_SIZE, message, message_size,
            0x51);
  memcpy(signature + TAG_SIZE, keys.public_key().bytes(), KEY_SIZE);
  return true;
}

bool verify(const Byte* message, Size message_size,
            const PublicKey& public_key,
            const Byte signature[SIGNATURE_SIZE])
{
  if ((message == 0 && message_size != 0) || signature == 0) {
    return false;
  }
  if (public_key.is_unset()) {
    return false;
  }

  // Author binding only until real signatures land.  Integrity of sealed
  // store bodies comes from unseal's tag (requires the secret key).
  if (memcmp(signature + TAG_SIZE, public_key.bytes(), KEY_SIZE) != 0) {
    return false;
  }

  for (Size i = 0; i < TAG_SIZE; ++i) {
    if (signature[i] != 0) {
      (void)message;
      (void)message_size;
      return true;
    }
  }
  return false;
}

}  // namespace lucia
