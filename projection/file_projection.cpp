#include "file_projection.h"

#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

namespace lucia {

namespace {

struct PendingChange {
  Size  record_index;
  Bytes bytes;
  String digest;
};

typedef std::vector<PendingChange> PendingChanges;

U32 rotate_right(U32 value, int bits)
{
  return (value >> bits) | (value << (32 - bits));
}

void digest_block(const Byte* block, U32 state[8])
{
  static const U32 constants[64] = {
    0x428a2f98u, 0x71374491u, 0xb5c0fbcfu, 0xe9b5dba5u,
    0x3956c25bu, 0x59f111f1u, 0x923f82a4u, 0xab1c5ed5u,
    0xd807aa98u, 0x12835b01u, 0x243185beu, 0x550c7dc3u,
    0x72be5d74u, 0x80deb1feu, 0x9bdc06a7u, 0xc19bf174u,
    0xe49b69c1u, 0xefbe4786u, 0x0fc19dc6u, 0x240ca1ccu,
    0x2de92c6fu, 0x4a7484aau, 0x5cb0a9dcu, 0x76f988dau,
    0x983e5152u, 0xa831c66du, 0xb00327c8u, 0xbf597fc7u,
    0xc6e00bf3u, 0xd5a79147u, 0x06ca6351u, 0x14292967u,
    0x27b70a85u, 0x2e1b2138u, 0x4d2c6dfcu, 0x53380d13u,
    0x650a7354u, 0x766a0abbu, 0x81c2c92eu, 0x92722c85u,
    0xa2bfe8a1u, 0xa81a664bu, 0xc24b8b70u, 0xc76c51a3u,
    0xd192e819u, 0xd6990624u, 0xf40e3585u, 0x106aa070u,
    0x19a4c116u, 0x1e376c08u, 0x2748774cu, 0x34b0bcb5u,
    0x391c0cb3u, 0x4ed8aa4au, 0x5b9cca4fu, 0x682e6ff3u,
    0x748f82eeu, 0x78a5636fu, 0x84c87814u, 0x8cc70208u,
    0x90befffau, 0xa4506cebu, 0xbef9a3f7u, 0xc67178f2u
  };

  U32 words[64];
  for (int i = 0; i < 16; ++i) {
    words[i] = (static_cast<U32>(block[i * 4]) << 24) |
               (static_cast<U32>(block[i * 4 + 1]) << 16) |
               (static_cast<U32>(block[i * 4 + 2]) << 8) |
               static_cast<U32>(block[i * 4 + 3]);
  }
  for (int i = 16; i < 64; ++i) {
    const U32 first =
        rotate_right(words[i - 15], 7) ^
        rotate_right(words[i - 15], 18) ^
        (words[i - 15] >> 3);
    const U32 second =
        rotate_right(words[i - 2], 17) ^
        rotate_right(words[i - 2], 19) ^
        (words[i - 2] >> 10);
    words[i] = words[i - 16] + first + words[i - 7] + second;
  }

  U32 a = state[0];
  U32 b = state[1];
  U32 c = state[2];
  U32 d = state[3];
  U32 e = state[4];
  U32 f = state[5];
  U32 g = state[6];
  U32 h = state[7];
  for (int i = 0; i < 64; ++i) {
    const U32 sum_one =
        rotate_right(e, 6) ^ rotate_right(e, 11) ^ rotate_right(e, 25);
    const U32 choice = (e & f) ^ ((~e) & g);
    const U32 temporary_one =
        h + sum_one + choice + constants[i] + words[i];
    const U32 sum_zero =
        rotate_right(a, 2) ^ rotate_right(a, 13) ^ rotate_right(a, 22);
    const U32 majority = (a & b) ^ (a & c) ^ (b & c);
    const U32 temporary_two = sum_zero + majority;
    h = g;
    g = f;
    f = e;
    e = d + temporary_one;
    d = c;
    c = b;
    b = a;
    a = temporary_one + temporary_two;
  }
  state[0] += a;
  state[1] += b;
  state[2] += c;
  state[3] += d;
  state[4] += e;
  state[5] += f;
  state[6] += g;
  state[7] += h;
}

String content_digest(const Bytes& bytes)
{
  U32 state[8] = {
    0x6a09e667u, 0xbb67ae85u, 0x3c6ef372u, 0xa54ff53au,
    0x510e527fu, 0x9b05688cu, 0x1f83d9abu, 0x5be0cd19u
  };

  Size offset = 0;
  while (bytes.size() - offset >= 64) {
    digest_block(bytes.data() + offset, state);
    offset += 64;
  }

  Byte final_blocks[128];
  memset(final_blocks, 0, sizeof(final_blocks));
  const Size remaining = bytes.size() - offset;
  if (remaining != 0) {
    memcpy(final_blocks, bytes.data() + offset, remaining);
  }
  final_blocks[remaining] = 0x80;
  const Size final_size = remaining < 56 ? 64 : 128;
  const U64 bit_size = static_cast<U64>(bytes.size()) * 8;
  for (int i = 0; i < 8; ++i) {
    final_blocks[final_size - 1 - i] =
        static_cast<Byte>((bit_size >> (i * 8)) & 0xffu);
  }
  digest_block(final_blocks, state);
  if (final_size == 128) {
    digest_block(final_blocks + 64, state);
  }

  char text[65];
  for (int word = 0; word < 8; ++word) {
    snprintf(text + word * 8, 9, "%08x",
             static_cast<unsigned int>(state[word]));
  }
  text[64] = '\0';
  return String(text);
}

bool entry_bytes(const Store& store, const ProjectionEntry& entry,
                 Bytes* bytes, U64* revision)
{
  Texel texel;
  OutputPort output;
  if (bytes == 0 || revision == 0 ||
      !store.get(entry.texel(), &texel) ||
      !texel.get_output(entry.output().c_str(), &output) ||
      output.type() != entry.type() ||
      !output.has_source() ||
      output.source().type() != entry.type()) {
    return false;
  }

  if (entry.type() == VALUE_TEXT) {
    const String& text = output.source().text();
    bytes->assign(text.begin(), text.end());
  } else if (!store.get_blob(output.source().blob(), bytes)) {
    return false;
  }
  *revision = output.revision();
  return true;
}

bool current_revision(const Store& store, const ProjectionRecord& record)
{
  Texel texel;
  OutputPort output;
  return store.get(record.entry().texel(), &texel) &&
         texel.get_output(record.entry().output().c_str(), &output) &&
         output.type() == record.entry().type() &&
         output.has_source() &&
         output.revision() == record.revision();
}

bool open_root(const String& directory, int* root)
{
  if (root == 0 || directory.empty()) {
    return false;
  }
  const int opened = open(directory.c_str(),
                          O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
  if (opened < 0) {
    return false;
  }
  *root = opened;
  return true;
}

bool open_parent(int root, const String& filename, bool create,
                 int* parent, String* leaf)
{
  if (root < 0 || parent == 0 || leaf == 0) {
    return false;
  }

  int directory = dup(root);
  if (directory < 0) {
    return false;
  }

  Size first = 0;
  Size slash = filename.find('/');
  while (slash != String::npos) {
    const String part = filename.substr(first, slash - first);
    int child = openat(directory, part.c_str(),
                       O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    if (child < 0 && create && errno == ENOENT) {
      if (mkdirat(directory, part.c_str(), 0700) != 0 && errno != EEXIST) {
        close(directory);
        return false;
      }
      child = openat(directory, part.c_str(),
                     O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    }
    if (child < 0) {
      close(directory);
      return false;
    }
    close(directory);
    directory = child;
    first = slash + 1;
    slash = filename.find('/', first);
  }

  *leaf = filename.substr(first);
  *parent = directory;
  return !leaf->empty();
}

bool read_file(int root, const String& filename, Bytes* bytes)
{
  int parent = -1;
  String leaf;
  if (bytes == 0 || !open_parent(root, filename, false, &parent, &leaf)) {
    return false;
  }

  const int file = openat(parent, leaf.c_str(),
                          O_RDONLY | O_NOFOLLOW | O_CLOEXEC);
  close(parent);
  if (file < 0) {
    return false;
  }

  struct stat status;
  if (fstat(file, &status) != 0 || !S_ISREG(status.st_mode) ||
      status.st_nlink != 1 || status.st_size < 0 ||
      static_cast<U64>(status.st_size) > static_cast<U64>(SIZE_MAX)) {
    close(file);
    return false;
  }

  Bytes loaded(static_cast<Size>(status.st_size));
  Size offset = 0;
  while (offset < loaded.size()) {
    const ssize_t count =
        ::read(file, loaded.data() + offset, loaded.size() - offset);
    if (count < 0 && errno == EINTR) {
      continue;
    }
    if (count <= 0) {
      close(file);
      return false;
    }
    offset += static_cast<Size>(count);
  }
  close(file);
  bytes->swap(loaded);
  return true;
}

bool write_file(int root, const String& filename, const Bytes& bytes)
{
  int parent = -1;
  String leaf;
  if (!open_parent(root, filename, true, &parent, &leaf)) {
    return false;
  }

  const int file = openat(parent, leaf.c_str(),
                          O_WRONLY | O_CREAT | O_NOFOLLOW | O_CLOEXEC,
                          0600);
  close(parent);
  if (file < 0) {
    return false;
  }

  struct stat status;
  if (fstat(file, &status) != 0 || !S_ISREG(status.st_mode) ||
      status.st_nlink != 1 || ftruncate(file, 0) != 0) {
    close(file);
    return false;
  }

  Size offset = 0;
  while (offset < bytes.size()) {
    const ssize_t count =
        ::write(file, bytes.data() + offset, bytes.size() - offset);
    if (count < 0 && errno == EINTR) {
      continue;
    }
    if (count <= 0) {
      close(file);
      return false;
    }
    offset += static_cast<Size>(count);
  }
  const bool saved = fsync(file) == 0;
  close(file);
  return saved;
}

bool check_tree(int directory, const String& prefix,
                const ProjectionManifest& manifest)
{
  const int scan_handle = dup(directory);
  if (scan_handle < 0) {
    return false;
  }
  DIR* scan = fdopendir(scan_handle);
  if (scan == 0) {
    close(scan_handle);
    return false;
  }

  bool valid = true;
  errno = 0;
  struct dirent* item = 0;
  while ((item = readdir(scan)) != 0) {
    if (strcmp(item->d_name, ".") == 0 ||
        strcmp(item->d_name, "..") == 0) {
      continue;
    }

    const String path =
        prefix.empty() ? String(item->d_name)
                       : prefix + "/" + item->d_name;
    struct stat status;
    if (fstatat(directory, item->d_name, &status,
                AT_SYMLINK_NOFOLLOW) != 0) {
      valid = false;
      break;
    }
    if (S_ISREG(status.st_mode)) {
      if (status.st_nlink != 1 || !manifest.has_file(path)) {
        valid = false;
        break;
      }
    } else if (S_ISDIR(status.st_mode) && manifest.has_directory(path)) {
      const int child =
          openat(directory, item->d_name,
                 O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
      if (child < 0 || !check_tree(child, path, manifest)) {
        if (child >= 0) {
          close(child);
        }
        valid = false;
        break;
      }
      close(child);
    } else {
      valid = false;
      break;
    }
    errno = 0;
  }
  if (valid && errno != 0) {
    valid = false;
  }
  closedir(scan);
  return valid;
}

bool put_change(Transaction* transaction, const ProjectionRecord& record,
                const Bytes& bytes)
{
  Texel texel;
  OutputPort output;
  if (transaction == 0 ||
      !transaction->get(record.entry().texel(), &texel) ||
      !texel.get_output(record.entry().output().c_str(), &output) ||
      output.type() != record.entry().type() ||
      output.revision() != record.revision()) {
    return false;
  }

  Value value;
  if (record.entry().type() == VALUE_TEXT) {
    const String text =
        bytes.empty()
            ? String()
            : String(reinterpret_cast<const char*>(bytes.data()), bytes.size());
    value = Value(text);
  } else {
    BlobRef reference;
    if (!transaction->put_blob(bytes, &reference)) {
      return false;
    }
    value = Value(reference);
  }

  return output.set_source(value) &&
         texel.put_output(output) &&
         transaction->put(texel);
}

}  // namespace

ProjectionRecord::ProjectionRecord()
    : source_revision(0)
{
}

ProjectionRecord::ProjectionRecord(const ProjectionEntry& entry, U64 revision,
                                   const String& digest)
    : projection_entry(entry),
      source_revision(revision),
      content_digest(digest)
{
}

const ProjectionEntry& ProjectionRecord::entry() const
{
  return projection_entry;
}

U64 ProjectionRecord::revision() const
{
  return source_revision;
}

const String& ProjectionRecord::digest() const
{
  return content_digest;
}

FileProjection::FileProjection()
    : exported(false)
{
}

bool FileProjection::export_from(const Store& store,
                                 const ProjectionManifest& manifest,
                                 const char* directory)
{
  if (!store.is_open() || manifest.size() == 0 ||
      directory == 0 || directory[0] == '\0') {
    return false;
  }

  int root = -1;
  if (!open_root(directory, &root) || !check_tree(root, "", manifest)) {
    if (root >= 0) {
      close(root);
    }
    return false;
  }

  ProjectionRecords captured;
  for (Size i = 0; i < manifest.size(); ++i) {
    ProjectionEntry entry;
    Bytes bytes;
    U64 revision = 0;
    if (!manifest.at(i, &entry) ||
        !entry_bytes(store, entry, &bytes, &revision) ||
        !write_file(root, entry.filename(), bytes)) {
      close(root);
      return false;
    }
    captured.push_back(
        ProjectionRecord(entry, revision, content_digest(bytes)));
  }
  close(root);

  projection_manifest = manifest;
  records.swap(captured);
  root_directory = directory;
  exported = true;
  return true;
}

bool FileProjection::import_changes(Store* store)
{
  if (!exported || store == 0 || !store->is_open()) {
    return false;
  }

  int root = -1;
  if (!open_root(root_directory, &root) ||
      !check_tree(root, "", projection_manifest)) {
    if (root >= 0) {
      close(root);
    }
    return false;
  }

  PendingChanges changes;
  for (Size i = 0; i < records.size(); ++i) {
    Bytes bytes;
    if (!current_revision(*store, records[i]) ||
        !read_file(root, records[i].entry().filename(), &bytes)) {
      close(root);
      return false;
    }
    const String digest = content_digest(bytes);
    if (digest != records[i].digest()) {
      PendingChange change;
      change.record_index = i;
      change.bytes.swap(bytes);
      change.digest = digest;
      changes.push_back(change);
    }
  }
  close(root);

  if (changes.empty()) {
    return true;
  }

  Transaction transaction;
  if (!store->begin(&transaction)) {
    return false;
  }
  for (Size i = 0; i < changes.size(); ++i) {
    if (!put_change(&transaction, records[changes[i].record_index],
                    changes[i].bytes)) {
      transaction.abort();
      return false;
    }
  }
  if (!transaction.commit()) {
    if (transaction.is_active()) {
      transaction.abort();
    }
    return false;
  }

  for (Size i = 0; i < changes.size(); ++i) {
    const Size index = changes[i].record_index;
    Texel texel;
    OutputPort output;
    if (!store->get(records[index].entry().texel(), &texel) ||
        !texel.get_output(records[index].entry().output().c_str(), &output)) {
      return false;
    }
    records[index] =
        ProjectionRecord(records[index].entry(), output.revision(),
                         changes[i].digest);
  }
  return true;
}

bool FileProjection::is_exported() const
{
  return exported;
}

Size FileProjection::size() const
{
  return records.size();
}

bool FileProjection::at(Size index, ProjectionRecord* record) const
{
  if (record == 0 || index >= records.size()) {
    return false;
  }
  *record = records[index];
  return true;
}

}  // namespace lucia
