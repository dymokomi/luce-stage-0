#include <fcntl.h>
#include <spawn.h>
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <unistd.h>

#include "fabric/model/output_port.h"
#include "fabric/model/texel.h"
#include "fabric/persistence/store.h"
#include "projection/file/file_projection.h"
#include "projection/file/projection_manifest.h"
#include "storage/volume/file_volume.h"
#include "storage/volume/volume.h"

using namespace lucia;

extern char **environ;

static int failures = 0;

#define CHECK(condition)                                                                   \
    do {                                                                                   \
        if (!(condition)) {                                                                \
            fprintf(stderr, "fail: %s (%s:%d)\n", #condition, __FILE__, __LINE__);         \
            ++failures;                                                                    \
        }                                                                                  \
    } while (0)

static bool write_bytes(const char *path, const Bytes &bytes) {
    FILE *file = fopen(path, "wb");
    if (file == 0) {
        return false;
    }
    const Size written = bytes.empty() ? 0 : fwrite(bytes.data(), 1, bytes.size(), file);
    const bool saved   = written == bytes.size() && fflush(file) == 0;
    const bool closed  = fclose(file) == 0;
    return saved && closed;
}

static bool run_sed(const char *path) {
    char *arguments[] = {const_cast<char *>("sed"),
                         const_cast<char *>("-i"),
                         const_cast<char *>(""),
                         const_cast<char *>("-e"),
                         const_cast<char *>("s/original/edited/"),
                         const_cast<char *>(path),
                         0};
    pid_t process     = 0;
    if (posix_spawn(&process, "/usr/bin/sed", 0, 0, arguments, environ) != 0) {
        return false;
    }
    int status = 0;
    return waitpid(process, &status, 0) == process && WIFEXITED(status) &&
           WEXITSTATUS(status) == 0;
}

static bool output_value(const Store &store, const TexelId &id, const char *name,
                         OutputPort *output) {
    Texel texel;
    return store.get(id, &texel) && texel.id().equals(id) && texel.get_output(name, output);
}

static void test_projection() {
    char  temporary[] = "/tmp/lucia-projection-XXXXXX";
    char *base        = mkdtemp(temporary);
    CHECK(base != 0);
    if (base == 0) {
        return;
    }

    String root      = String(base) + "/files";
    String image     = String(base) + "/store.img";
    String text_path = root + "/notes/message.txt";
    String blob_path = root + "/assets/data.bin";
    CHECK(mkdir(root.c_str(), 0700) == 0);

    TexelId text_id;
    TexelId blob_id;
    CHECK(text_id.generate());
    CHECK(blob_id.generate());

    Bytes original_blob(PAGE_SIZE * 3 + 37);
    for (Size i = 0; i < original_blob.size(); ++i) {
        original_blob[i] = static_cast<Byte>((i * 17 + 3) & 0xff);
    }
    Bytes edited_blob = original_blob;
    for (Size i = PAGE_SIZE - 5; i < edited_blob.size(); i += PAGE_SIZE) {
        edited_blob[i] ^= 0x5a;
    }

    if (true) {
        FileVolume volume;
        CHECK(volume.create(image.c_str(), 256));
        Store store;
        CHECK(store.create(&volume));

        Transaction transaction;
        CHECK(store.begin(&transaction));

        Texel      text(text_id);
        OutputPort text_output("text", VALUE_TEXT);
        CHECK(text_output.set_source(Value("original text\n")));
        CHECK(text.put_output(text_output));
        CHECK(transaction.put(text));

        BlobRef blob_reference;
        CHECK(transaction.put_blob(original_blob, &blob_reference));
        Texel      blob(blob_id);
        OutputPort blob_output("blob", VALUE_BLOB);
        CHECK(blob_output.set_source(Value(blob_reference)));
        CHECK(blob.put_output(blob_output));
        CHECK(transaction.put(blob));
        CHECK(transaction.commit());

        ProjectionManifest rejected;
        CHECK(!rejected.put(ProjectionEntry(text_id, "text", VALUE_TEXT, "/absolute")));
        CHECK(!rejected.put(ProjectionEntry(text_id, "text", VALUE_TEXT, "../escape")));
        CHECK(
            !rejected.put(ProjectionEntry(text_id, "text", VALUE_TEXT, "a/../../escape")));
        CHECK(!rejected.put(ProjectionEntry(text_id, "text", VALUE_TEXT, "a\\escape")));
        CHECK(!rejected.put(ProjectionEntry(text_id, "text", VALUE_BYTES, "bytes.bin")));

        ProjectionManifest manifest;
        CHECK(manifest.put(
            ProjectionEntry(text_id, "text", VALUE_TEXT, "notes/message.txt")));
        CHECK(
            manifest.put(ProjectionEntry(blob_id, "blob", VALUE_BLOB, "assets/data.bin")));
        CHECK(!manifest.put(
            ProjectionEntry(blob_id, "other", VALUE_BLOB, "assets/data.bin")));
        CHECK(
            !manifest.put(ProjectionEntry(text_id, "text", VALUE_TEXT, "notes/other.txt")));

        FileProjection projection;
        CHECK(projection.export_from(store, manifest, root.c_str()));
        CHECK(projection.is_exported());
        CHECK(projection.size() == 2);

        ProjectionRecord record;
        CHECK(projection.at(0, &record));
        CHECK(record.revision() != 0);
        CHECK(record.digest() ==
              "84bd16f91ec8f223cad47630cf98cc04521ba112acb13942d20865060c28f3d3");

        CHECK(run_sed(text_path.c_str()));
        CHECK(write_bytes(blob_path.c_str(), edited_blob));

        const String extra_path = root + "/extra.txt";
        const Bytes  extra(1, static_cast<Byte>('x'));
        CHECK(write_bytes(extra_path.c_str(), extra));
        CHECK(!projection.import_changes(&store));
        CHECK(unlink(extra_path.c_str()) == 0);

        const String saved_path = text_path + ".saved";
        CHECK(rename(text_path.c_str(), saved_path.c_str()) == 0);
        CHECK(symlink("/etc/passwd", text_path.c_str()) == 0);
        CHECK(!projection.import_changes(&store));
        CHECK(unlink(text_path.c_str()) == 0);
        CHECK(rename(saved_path.c_str(), text_path.c_str()) == 0);

        CHECK(projection.import_changes(&store));
        CHECK(store.size() == 2);
        CHECK(store.has(text_id));
        CHECK(store.has(blob_id));

        OutputPort imported_text;
        CHECK(output_value(store, text_id, "text", &imported_text));
        CHECK(imported_text.source().text() == "edited text\n");

        OutputPort imported_blob;
        Bytes      imported_bytes;
        CHECK(output_value(store, blob_id, "blob", &imported_blob));
        CHECK(store.get_blob(imported_blob.source().blob(), &imported_bytes));
        CHECK(imported_bytes == edited_blob);

        volume.close();
    }

    if (true) {
        FileVolume volume;
        CHECK(volume.open(image.c_str()));
        Store reopened;
        CHECK(reopened.open(&volume));
        CHECK(reopened.size() == 2);
        CHECK(reopened.has(text_id));
        CHECK(reopened.has(blob_id));

        OutputPort persisted_text;
        CHECK(output_value(reopened, text_id, "text", &persisted_text));
        CHECK(persisted_text.source().text() == "edited text\n");

        OutputPort persisted_blob;
        Bytes      persisted_bytes;
        CHECK(output_value(reopened, blob_id, "blob", &persisted_blob));
        CHECK(reopened.get_blob(persisted_blob.source().blob(), &persisted_bytes));
        CHECK(persisted_bytes == edited_blob);
        volume.close();
    }

    CHECK(unlink(text_path.c_str()) == 0);
    CHECK(unlink(blob_path.c_str()) == 0);
    CHECK(rmdir((root + "/notes").c_str()) == 0);
    CHECK(rmdir((root + "/assets").c_str()) == 0);
    CHECK(rmdir(root.c_str()) == 0);
    CHECK(unlink(image.c_str()) == 0);
    CHECK(rmdir(base) == 0);
}

int main() {
    test_projection();
    if (failures != 0) {
        fprintf(stderr, "%d checks failed\n", failures);
        return 1;
    }
    printf("ok\n");
    return 0;
}
