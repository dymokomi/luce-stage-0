#include "principal.h"

namespace lucia {

Principal::Principal()
{
}

bool Principal::create()
{
  return key_pair.generate();
}

bool Principal::set_secret(const Byte* secret)
{
  return key_pair.set_secret(secret);
}

bool Principal::is_unset() const
{
  return key_pair.public_key().is_unset();
}

const PublicKey& Principal::public_key() const
{
  return key_pair.public_key();
}

const KeyPair& Principal::keys() const
{
  return key_pair;
}

const Byte* Principal::seal_key() const
{
  return key_pair.secret_bytes();
}

}  // namespace lucia
