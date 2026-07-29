#include "fabric/persistence/encode.h"

#include <algorithm>
#include <limits.h>
#include <string.h>

namespace lucia {

namespace {

enum { SNAPSHOT_VERSION = 1, SNAPSHOT_MAGIC_SIZE = 8 };

const Byte SNAPSHOT_MAGIC[SNAPSHOT_MAGIC_SIZE] = {'L', 'U', 'T', 'E', 'X', 'E', 'L', '\0'};

typedef std::map<TexelId, Size> TexelIndexes;
typedef std::map<String, Size>  BlobIndexes;
typedef std::map<TexelId, Byte> VisitTable;

bool temporal_evaluator(const String &evaluator) {
    return evaluator == "loom.state" || evaluator == "loom.delay";
}

bool valid_temporal_texel(const Texel &texel) {
    if (!temporal_evaluator(texel.evaluator()) || texel.input_size() != 1 ||
        texel.output_size() != 1) {
        return false;
    }

    InputPort  input;
    OutputPort output;
    return texel.get_input("next", &input) && texel.get_output("value", &output) &&
           input.type() == output.type() && output.has_source() &&
           output.source().type() == output.type();
}

bool add_size(Size left, Size right, Size *result) {
    if (result == 0 || right > SIZE_MAX - left) {
        return false;
    }
    *result = left + right;
    return true;
}

bool write_bytes(Bytes *output, const Byte *data, Size size) {
    Size total = 0;
    if (output == 0 || !add_size(output->size(), size, &total) ||
        total > output->max_size()) {
        return false;
    }
    if (size == 0) {
        return true;
    }
    if (data == 0) {
        return false;
    }
    output->insert(output->end(), data, data + size);
    return true;
}

bool write_u8(Bytes *output, Byte value) {
    return write_bytes(output, &value, 1);
}

bool write_u32(Bytes *output, U32 value) {
    Byte data[4];
    for (int i = 0; i < 4; ++i) {
        data[i] = static_cast<Byte>((value >> (i * 8)) & 0xffu);
    }
    return write_bytes(output, data, sizeof(data));
}

bool write_u64(Bytes *output, U64 value) {
    Byte data[8];
    for (int i = 0; i < 8; ++i) {
        data[i] = static_cast<Byte>((value >> (i * 8)) & 0xffu);
    }
    return write_bytes(output, data, sizeof(data));
}

bool write_string(Bytes *output, const String &text) {
    return write_u64(output, static_cast<U64>(text.size())) &&
           write_bytes(output, reinterpret_cast<const Byte *>(text.data()), text.size());
}

class Reader {
public:
    Reader(const Byte *bytes, Size byte_size) : data(bytes), size(byte_size), offset(0) {}

    bool read(Byte *output, Size count) {
        if ((data == 0 && size != 0) || count > size - offset ||
            (output == 0 && count != 0)) {
            return false;
        }
        if (count != 0) {
            memcpy(output, data + offset, count);
        }
        offset += count;
        return true;
    }

    bool u8(Byte *value) {
        return read(value, 1);
    }

    bool u32(U32 *value) {
        Byte bytes[4];
        if (value == 0 || !read(bytes, sizeof(bytes))) {
            return false;
        }
        *value = static_cast<U32>(bytes[0]) | (static_cast<U32>(bytes[1]) << 8) |
                 (static_cast<U32>(bytes[2]) << 16) | (static_cast<U32>(bytes[3]) << 24);
        return true;
    }

    bool u64(U64 *value) {
        Byte bytes[8];
        if (value == 0 || !read(bytes, sizeof(bytes))) {
            return false;
        }
        U64 result = 0;
        for (int i = 0; i < 8; ++i) {
            result |= static_cast<U64>(bytes[i]) << (i * 8);
        }
        *value = result;
        return true;
    }

    bool string(String *text) {
        U64 length = 0;
        if (text == 0 || !u64(&length) || length > static_cast<U64>(SIZE_MAX) ||
            static_cast<Size>(length) > remaining()) {
            return false;
        }
        text->assign(reinterpret_cast<const char *>(data + offset),
                     static_cast<Size>(length));
        offset += static_cast<Size>(length);
        return true;
    }

    Size remaining() const {
        return size - offset;
    }

    bool done() const {
        return offset == size;
    }

    const Byte *current() const {
        return data + offset;
    }

    bool skip(Size count) {
        if (count > remaining()) {
            return false;
        }
        offset += count;
        return true;
    }

private:
    const Byte *data;
    Size        size;
    Size        offset;
};

bool encode_value(const Value &value, Bytes *output) {
    if (value.type() < VALUE_BOOL || value.type() > VALUE_BLOB ||
        !write_u8(output, static_cast<Byte>(value.type()))) {
        return false;
    }

    switch (value.type()) {
    case VALUE_BOOL:
        return write_u8(output, value.boolean() ? 1 : 0);
    case VALUE_INT:
        return write_u64(output, static_cast<U64>(value.integer()));
    case VALUE_REAL: {
        U64    bits   = 0;
        double number = value.real();
        memcpy(&bits, &number, sizeof(bits));
        return write_u64(output, bits);
    }
    case VALUE_TEXT:
        return write_string(output, value.text());
    case VALUE_BYTES:
        return write_u64(output, static_cast<U64>(value.bytes().size())) &&
               write_bytes(output, value.bytes().data(), value.bytes().size());
    case VALUE_TEXEL:
        return !value.texel().is_unset() &&
               write_bytes(output, value.texel().bytes(), TexelId::SIZE);
    case VALUE_BLOB:
        return !value.blob().is_unset() &&
               write_bytes(output, value.blob().id(), BlobRef::ID_SIZE) &&
               write_u64(output, value.blob().size());
    case VALUE_NONE:
        break;
    }
    return false;
}

bool decode_value(Reader *reader, Value *value) {
    Byte type = 0;
    if (reader == 0 || value == 0 || !reader->u8(&type) || type < VALUE_BOOL ||
        type > VALUE_BLOB) {
        return false;
    }

    switch (type) {
    case VALUE_BOOL: {
        Byte flag = 0;
        if (!reader->u8(&flag) || flag > 1) {
            return false;
        }
        *value = Value(flag == 1);
        return true;
    }
    case VALUE_INT: {
        U64 bits   = 0;
        S64 number = 0;
        if (!reader->u64(&bits)) {
            return false;
        }
        memcpy(&number, &bits, sizeof(number));
        *value = Value(number);
        return true;
    }
    case VALUE_REAL: {
        U64    bits   = 0;
        double number = 0.0;
        if (!reader->u64(&bits)) {
            return false;
        }
        memcpy(&number, &bits, sizeof(number));
        *value = Value(number);
        return true;
    }
    case VALUE_TEXT: {
        String text;
        if (!reader->string(&text)) {
            return false;
        }
        *value = Value(text);
        return true;
    }
    case VALUE_BYTES: {
        U64 length = 0;
        if (!reader->u64(&length) || length > static_cast<U64>(SIZE_MAX) ||
            static_cast<Size>(length) > reader->remaining()) {
            return false;
        }
        *value = Value(reader->current(), static_cast<Size>(length));
        return reader->skip(static_cast<Size>(length));
    }
    case VALUE_TEXEL: {
        Byte    bytes[TexelId::SIZE];
        TexelId id;
        if (!reader->read(bytes, sizeof(bytes))) {
            return false;
        }
        id.set_bytes(bytes);
        if (id.is_unset()) {
            return false;
        }
        *value = Value(id);
        return true;
    }
    case VALUE_BLOB: {
        Byte id[BlobRef::ID_SIZE];
        U64  size = 0;
        if (!reader->read(id, sizeof(id)) || !reader->u64(&size)) {
            return false;
        }
        BlobRef reference(id, size);
        if (reference.is_unset()) {
            return false;
        }
        *value = Value(reference);
        return true;
    }
    }
    return false;
}

bool encode_texel_body(const Texel &texel, Bytes *output) {
    if (!texel.valid() || output == 0 || texel.input_size() > 0xffffffffu ||
        texel.output_size() > 0xffffffffu) {
        return false;
    }

    output->clear();
    if (!write_bytes(output, texel.id().bytes(), TexelId::SIZE) ||
        !write_u8(output, texel.has_content() ? 1 : 0) ||
        (texel.has_content() && !encode_value(texel.content(), output)) ||
        !write_string(output, texel.evaluator()) || !write_u64(output, texel.revision()) ||
        !write_u32(output, static_cast<U32>(texel.input_size()))) {
        return false;
    }

    for (Size i = 0; i < texel.input_size(); ++i) {
        InputPort port;
        if (!texel.input_at(i, &port) || !write_string(output, port.name()) ||
            !write_u8(output, static_cast<Byte>(port.type())) ||
            !write_u8(output, port.has_binding() ? 1 : 0)) {
            return false;
        }
        if (port.has_binding() &&
            (!write_bytes(output, port.binding().source().bytes(), TexelId::SIZE) ||
             !write_string(output, port.binding().output()))) {
            return false;
        }
    }

    if (!write_u32(output, static_cast<U32>(texel.output_size()))) {
        return false;
    }
    for (Size i = 0; i < texel.output_size(); ++i) {
        OutputPort port;
        if (!texel.output_at(i, &port) || !write_string(output, port.name()) ||
            !write_u8(output, static_cast<Byte>(port.type())) ||
            !write_u8(output, port.has_source() ? 1 : 0) ||
            (port.has_source() && !encode_value(port.source(), output)) ||
            !write_u64(output, port.revision())) {
            return false;
        }
    }
    return true;
}

bool decode_texel_body(const Byte *data, Size size, Texel *output) {
    if (data == 0 || output == 0) {
        return false;
    }

    Reader  reader(data, size);
    Byte    id_bytes[TexelId::SIZE];
    Byte    flag = 0;
    TexelId id;
    Texel   texel;
    if (!reader.read(id_bytes, sizeof(id_bytes))) {
        return false;
    }
    id.set_bytes(id_bytes);
    if (id.is_unset()) {
        return false;
    }
    texel.set_id(id);

    if (!reader.u8(&flag) || flag > 1) {
        return false;
    }
    if (flag == 1) {
        Value content;
        if (!decode_value(&reader, &content) || !texel.set_content(content)) {
            return false;
        }
    }

    String evaluator;
    U64    revision    = 0;
    U32    input_count = 0;
    if (!reader.string(&evaluator) ||
        (!evaluator.empty() && !texel.set_evaluator(evaluator.c_str())) ||
        !reader.u64(&revision) || !reader.u32(&input_count) ||
        static_cast<U64>(input_count) > static_cast<U64>(reader.remaining())) {
        return false;
    }
    texel.set_revision(revision);

    for (U32 i = 0; i < input_count; ++i) {
        String name;
        Byte   type  = 0;
        Byte   bound = 0;
        if (!reader.string(&name) || name.empty() || texel.has_input(name.c_str()) ||
            !reader.u8(&type) || type < VALUE_BOOL || type > VALUE_BLOB ||
            !reader.u8(&bound) || bound > 1) {
            return false;
        }
        InputPort port(name.c_str(), static_cast<ValueType>(type));
        if (bound == 1) {
            Byte    source_bytes[TexelId::SIZE];
            String  output_name;
            TexelId source;
            if (!reader.read(source_bytes, sizeof(source_bytes)) ||
                !reader.string(&output_name)) {
                return false;
            }
            source.set_bytes(source_bytes);
            Fiber fiber(source, output_name.c_str());
            if (!port.bind(fiber)) {
                return false;
            }
        }
        if (!texel.put_input(port)) {
            return false;
        }
    }

    U32 output_count = 0;
    if (!reader.u32(&output_count) ||
        static_cast<U64>(output_count) > static_cast<U64>(reader.remaining())) {
        return false;
    }
    for (U32 i = 0; i < output_count; ++i) {
        String name;
        Byte   type       = 0;
        Byte   has_source = 0;
        if (!reader.string(&name) || name.empty() || texel.has_output(name.c_str()) ||
            !reader.u8(&type) || type < VALUE_BOOL || type > VALUE_BLOB ||
            !reader.u8(&has_source) || has_source > 1) {
            return false;
        }
        OutputPort port(name.c_str(), static_cast<ValueType>(type));
        if (has_source == 1) {
            Value source;
            if (!decode_value(&reader, &source) || !port.set_source(source)) {
                return false;
            }
        }
        U64 source_revision = 0;
        if (!reader.u64(&source_revision)) {
            return false;
        }
        port.set_revision(source_revision);
        if (!texel.put_output(port)) {
            return false;
        }
    }

    if (!reader.done() || !texel.valid()) {
        return false;
    }
    *output = texel;
    return true;
}

String blob_key(const Byte *id) {
    return String(reinterpret_cast<const char *>(id), BlobRef::ID_SIZE);
}

bool value_references_valid(const Value &value, const TexelIndexes &texels,
                            const BlobIndexes &blobs, const BlobRecords &records) {
    if (value.type() == VALUE_TEXEL) {
        return !value.texel().is_unset() && texels.find(value.texel()) != texels.end();
    }
    if (value.type() != VALUE_BLOB) {
        return value.type() >= VALUE_BOOL && value.type() < VALUE_TEXEL;
    }
    if (value.blob().is_unset()) {
        return false;
    }
    BlobIndexes::const_iterator found = blobs.find(blob_key(value.blob().id()));
    return found != blobs.end() &&
           records[found->second].reference.size() == value.blob().size();
}

bool visit(const TexelId &id, const Texels &texels, const TexelIndexes &indexes,
           VisitTable *visits) {
    VisitTable::iterator state = visits->find(id);
    if (state != visits->end()) {
        return state->second == 2;
    }
    (*visits)[id] = 1;

    const Texel &target = texels[indexes.find(id)->second];
    if (temporal_evaluator(target.evaluator())) {
        (*visits)[id] = 2;
        return true;
    }
    for (Size i = 0; i < target.input_size(); ++i) {
        InputPort input;
        if (!target.input_at(i, &input)) {
            return false;
        }
        if (!input.has_binding()) {
            continue;
        }
        VisitTable::iterator source_state = visits->find(input.binding().source());
        if (source_state != visits->end() && source_state->second == 1) {
            return false;
        }
        if (source_state == visits->end() &&
            !visit(input.binding().source(), texels, indexes, visits)) {
            return false;
        }
    }
    (*visits)[id] = 2;
    return true;
}

bool texel_less(const Texel &left, const Texel &right) {
    return left.id().less_than(right.id());
}

bool blob_less(const BlobRecord &left, const BlobRecord &right) {
    return memcmp(left.reference.id(), right.reference.id(), BlobRef::ID_SIZE) < 0;
}

} // namespace

bool encode_texel(const Texel &texel, Bytes *output) {
    return encode_texel_body(texel, output);
}

bool decode_texel(const Byte *data, Size size, Texel *output) {
    return decode_texel_body(data, size, output);
}

bool validate_snapshot(const Texels &texels, const BlobRecords &blobs) {
    TexelIndexes texel_indexes;
    BlobIndexes  blob_indexes;

    for (Size i = 0; i < blobs.size(); ++i) {
        const BlobRecord &blob = blobs[i];
        String            key  = blob_key(blob.reference.id());
        if (blob.reference.is_unset() ||
            blob.reference.size() != static_cast<U64>(blob.bytes.size()) ||
            blob_indexes.find(key) != blob_indexes.end()) {
            return false;
        }
        blob_indexes[key] = i;
    }

    for (Size i = 0; i < texels.size(); ++i) {
        const Texel &texel = texels[i];
        if (!texel.valid() ||
            (temporal_evaluator(texel.evaluator()) && !valid_temporal_texel(texel)) ||
            texel_indexes.find(texel.id()) != texel_indexes.end()) {
            return false;
        }
        texel_indexes[texel.id()] = i;
    }

    for (Size i = 0; i < texels.size(); ++i) {
        const Texel &texel = texels[i];
        if (texel.has_content() &&
            !value_references_valid(texel.content(), texel_indexes, blob_indexes, blobs)) {
            return false;
        }
        for (Size input_index = 0; input_index < texel.input_size(); ++input_index) {
            InputPort input;
            if (!texel.input_at(input_index, &input)) {
                return false;
            }
            if (!input.has_binding()) {
                continue;
            }
            TexelIndexes::const_iterator source =
                texel_indexes.find(input.binding().source());
            if (source == texel_indexes.end()) {
                return false;
            }
            OutputPort output;
            if (!texels[source->second].get_output(input.binding().output().c_str(),
                                                   &output) ||
                output.type() != input.type()) {
                return false;
            }
        }
        for (Size output_index = 0; output_index < texel.output_size(); ++output_index) {
            OutputPort output;
            if (!texel.output_at(output_index, &output) ||
                (output.has_source() &&
                 !value_references_valid(output.source(), texel_indexes, blob_indexes,
                                         blobs))) {
                return false;
            }
        }
    }

    VisitTable visits;
    for (Size i = 0; i < texels.size(); ++i) {
        if (visits.find(texels[i].id()) == visits.end() &&
            !visit(texels[i].id(), texels, texel_indexes, &visits)) {
            return false;
        }
    }
    return true;
}

bool encode_snapshot(const Texels &texels, const BlobRecords &blobs, Bytes *output) {
    if (output == 0 || texels.size() > 0xffffffffu || blobs.size() > 0xffffffffu ||
        !validate_snapshot(texels, blobs)) {
        return false;
    }

    Texels      sorted_texels = texels;
    BlobRecords sorted_blobs  = blobs;
    std::sort(sorted_texels.begin(), sorted_texels.end(), texel_less);
    std::sort(sorted_blobs.begin(), sorted_blobs.end(), blob_less);

    Bytes encoded;
    if (!write_bytes(&encoded, SNAPSHOT_MAGIC, sizeof(SNAPSHOT_MAGIC)) ||
        !write_u32(&encoded, SNAPSHOT_VERSION) ||
        !write_u32(&encoded, static_cast<U32>(sorted_texels.size()))) {
        return false;
    }
    for (Size i = 0; i < sorted_texels.size(); ++i) {
        Bytes texel;
        if (!encode_texel_body(sorted_texels[i], &texel) ||
            !write_u64(&encoded, static_cast<U64>(texel.size())) ||
            !write_bytes(&encoded, texel.data(), texel.size())) {
            return false;
        }
    }

    if (!write_u32(&encoded, static_cast<U32>(sorted_blobs.size()))) {
        return false;
    }
    for (Size i = 0; i < sorted_blobs.size(); ++i) {
        const BlobRecord &blob = sorted_blobs[i];
        if (!write_bytes(&encoded, blob.reference.id(), BlobRef::ID_SIZE) ||
            !write_u64(&encoded, blob.reference.size()) ||
            !write_bytes(&encoded, blob.bytes.data(), blob.bytes.size())) {
            return false;
        }
    }
    output->swap(encoded);
    return true;
}

bool decode_snapshot(const Byte *data, Size size, Texels *texels, BlobRecords *blobs) {
    if (data == 0 || texels == 0 || blobs == 0) {
        return false;
    }

    Reader       reader(data, size);
    Byte         magic[SNAPSHOT_MAGIC_SIZE];
    U32          version     = 0;
    U32          texel_count = 0;
    Texels       decoded_texels;
    BlobRecords  decoded_blobs;
    TexelIndexes texel_indexes;
    BlobIndexes  blob_indexes;

    if (!reader.read(magic, sizeof(magic)) ||
        memcmp(magic, SNAPSHOT_MAGIC, sizeof(magic)) != 0 || !reader.u32(&version) ||
        version != SNAPSHOT_VERSION || !reader.u32(&texel_count) ||
        static_cast<U64>(texel_count) > static_cast<U64>(reader.remaining() / 8)) {
        return false;
    }

    for (U32 i = 0; i < texel_count; ++i) {
        U64 encoded_size = 0;
        if (!reader.u64(&encoded_size) || encoded_size == 0 ||
            encoded_size > static_cast<U64>(SIZE_MAX) ||
            static_cast<Size>(encoded_size) > reader.remaining()) {
            return false;
        }
        Texel texel;
        if (!decode_texel_body(reader.current(), static_cast<Size>(encoded_size), &texel) ||
            texel_indexes.find(texel.id()) != texel_indexes.end() ||
            !reader.skip(static_cast<Size>(encoded_size))) {
            return false;
        }
        texel_indexes[texel.id()] = decoded_texels.size();
        decoded_texels.push_back(texel);
    }

    U32 blob_count = 0;
    if (!reader.u32(&blob_count) ||
        static_cast<U64>(blob_count) >
            static_cast<U64>(reader.remaining() / (BlobRef::ID_SIZE + sizeof(U64)))) {
        return false;
    }
    for (U32 i = 0; i < blob_count; ++i) {
        Byte id[BlobRef::ID_SIZE];
        U64  byte_size = 0;
        if (!reader.read(id, sizeof(id)) || !reader.u64(&byte_size) ||
            byte_size > static_cast<U64>(SIZE_MAX) ||
            static_cast<Size>(byte_size) > reader.remaining()) {
            return false;
        }
        BlobRecord blob;
        blob.reference = BlobRef(id, byte_size);
        String key     = blob_key(id);
        if (blob.reference.is_unset() || blob_indexes.find(key) != blob_indexes.end()) {
            return false;
        }
        blob.bytes.assign(reader.current(),
                          reader.current() + static_cast<Size>(byte_size));
        if (!reader.skip(static_cast<Size>(byte_size))) {
            return false;
        }
        blob_indexes[key] = decoded_blobs.size();
        decoded_blobs.push_back(blob);
    }

    if (!reader.done() || !validate_snapshot(decoded_texels, decoded_blobs)) {
        return false;
    }
    texels->swap(decoded_texels);
    blobs->swap(decoded_blobs);
    return true;
}

} // namespace lucia
