#include "platform/io/file.h"

#include <fcntl.h>
#include <limits.h>
#include <unistd.h>

namespace lucia {

PlatformFile::PlatformFile() : handle(-1) {}

PlatformFile::~PlatformFile() {
    close();
}

bool PlatformFile::is_open() const {
    return handle >= 0;
}

void PlatformFile::close() {
    if (is_open()) {
        ::close(handle);
        handle = -1;
    }
}

bool PlatformFile::create(const char *path, uint64_t byte_size) {
    if (path == 0 || byte_size == 0 || byte_size > (uint64_t)INT64_MAX) {
        return false;
    }

    close();
    handle = ::open(path, O_RDWR | O_CREAT | O_TRUNC | O_CLOEXEC, 0600);
    if (!is_open()) {
        return false;
    }
    if (ftruncate(handle, (off_t)byte_size) != 0) {
        close();
        return false;
    }
    return true;
}

bool PlatformFile::open(const char *path) {
    if (path == 0) {
        return false;
    }

    close();
    handle = ::open(path, O_RDWR | O_CLOEXEC);
    return is_open();
}

bool PlatformFile::size(uint64_t *byte_size) const {
    if (!is_open() || byte_size == 0) {
        return false;
    }

    const off_t result = lseek(handle, 0, SEEK_END);
    if (result < 0 || lseek(handle, 0, SEEK_SET) < 0) {
        return false;
    }
    *byte_size = (uint64_t)result;
    return true;
}

bool PlatformFile::read(uint64_t byte_offset, void *destination, size_t byte_count) {
    if (!is_open() || destination == 0 || byte_offset > (uint64_t)INT64_MAX) {
        return false;
    }
    const ssize_t count = pread(handle, destination, byte_count, (off_t)byte_offset);
    return count >= 0 && (size_t)count == byte_count;
}

bool PlatformFile::write(uint64_t byte_offset, const void *source, size_t byte_count) {
    if (!is_open() || source == 0 || byte_offset > (uint64_t)INT64_MAX) {
        return false;
    }
    const ssize_t count = pwrite(handle, source, byte_count, (off_t)byte_offset);
    return count >= 0 && (size_t)count == byte_count;
}

bool PlatformFile::flush() {
    return is_open() && fsync(handle) == 0;
}

} // namespace lucia
