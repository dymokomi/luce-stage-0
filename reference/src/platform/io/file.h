#pragma once

#include <stddef.h>
#include <stdint.h>

namespace lucia {

// ---------------------------------------------------------------------------
// PlatformFile
// ---------------------------------------------------------------------------
//
// Small host-file boundary used by storage. Offsets and sizes are bytes.
//
class PlatformFile {
public:
    PlatformFile();
    ~PlatformFile();

    bool create(const char *path, uint64_t byte_size);
    bool open(const char *path);
    void close();

    bool is_open() const;
    bool size(uint64_t *byte_size) const;
    bool read(uint64_t byte_offset, void *destination, size_t byte_count);
    bool write(uint64_t byte_offset, const void *source, size_t byte_count);
    bool flush();

private:
    PlatformFile(const PlatformFile &);
    PlatformFile &operator=(const PlatformFile &);

    int handle;
};

} // namespace lucia
