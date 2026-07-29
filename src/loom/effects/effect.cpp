#include "loom/effects/effect.h"

#include <limits.h>
#include <string.h>

namespace lucia {

namespace {

enum { EFFECT_VERSION = 1, EFFECT_MAGIC_SIZE = 8, MAX_NAME_SIZE = 4096 };

const Byte INTENT_MAGIC[EFFECT_MAGIC_SIZE]      = {'L', 'U', 'E', 'F', 'I', 'N', 'T', '\0'};
const Byte OBSERVATION_MAGIC[EFFECT_MAGIC_SIZE] = {'L', 'U', 'E', 'F', 'O', 'B', 'S', '\0'};

bool id_is_zero(const Byte *id) {
    if (id == 0) {
        return true;
    }
    for (Size i = 0; i < EffectIntent::REQUEST_ID_SIZE; ++i) {
        if (id[i] != 0) {
            return false;
        }
    }
    return true;
}

bool valid_name(const String &name) {
    return !name.empty() && name.size() <= MAX_NAME_SIZE && name.find('\0') == String::npos;
}

void write_u32(Bytes *bytes, U32 value) {
    for (int i = 0; i < 4; ++i) {
        bytes->push_back(static_cast<Byte>((value >> (i * 8)) & 0xffu));
    }
}

bool read_u32(const Bytes &bytes, Size *offset, U32 *value) {
    if (offset == 0 || value == 0 || *offset > bytes.size() || bytes.size() - *offset < 4) {
        return false;
    }
    const Byte *data = bytes.data() + *offset;
    *value           = static_cast<U32>(data[0]) | (static_cast<U32>(data[1]) << 8) |
             (static_cast<U32>(data[2]) << 16) | (static_cast<U32>(data[3]) << 24);
    *offset += 4;
    return true;
}

bool read_string(const Bytes &bytes, Size *offset, String *text) {
    U32 size = 0;
    if (text == 0 || !read_u32(bytes, offset, &size) || size > MAX_NAME_SIZE ||
        *offset > bytes.size() || static_cast<Size>(size) > bytes.size() - *offset) {
        return false;
    }
    text->assign(reinterpret_cast<const char *>(bytes.data() + *offset), size);
    *offset += size;
    return valid_name(*text);
}

bool read_bytes(const Bytes &bytes, Size *offset, Bytes *output) {
    U32 size = 0;
    if (output == 0 || !read_u32(bytes, offset, &size) || *offset > bytes.size() ||
        static_cast<Size>(size) > bytes.size() - *offset) {
        return false;
    }
    output->assign(bytes.begin() + *offset,
                   bytes.begin() + *offset + static_cast<Size>(size));
    *offset += static_cast<Size>(size);
    return true;
}

bool available_bytes(const ValueOutcome &outcome, const Value **value) {
    if (value == 0 || outcome.status() != VALUE_AVAILABLE ||
        outcome.value().type() != VALUE_BYTES) {
        return false;
    }
    *value = &outcome.value();
    return true;
}

bool same_request(const Byte *left, const Byte *right) {
    return left != 0 && right != 0 &&
           memcmp(left, right, EffectIntent::REQUEST_ID_SIZE) == 0;
}

bool load_observation(const Store *store, const TexelId &id,
                      EffectObservation *observation) {
    Texel      texel;
    OutputPort output;
    return store != 0 && observation != 0 && store->get(id, &texel) &&
           texel.input_size() == 0 && texel.output_size() == 1 &&
           texel.get_output("observation", &output) && output.type() == VALUE_BYTES &&
           output.has_source() && decode_effect_observation(output.source(), observation);
}

} // namespace

EffectIntent::EffectIntent() {
    memset(id, 0, sizeof(id));
}

bool EffectIntent::set(const Byte *request_id, const char *operation, const char *target,
                       const Bytes &payload) {
    if (id_is_zero(request_id) || operation == 0 || target == 0) {
        return false;
    }
    const String operation_text(operation);
    const String target_text(target);
    if (!valid_name(operation_text) || !valid_name(target_text) ||
        payload.size() > UINT32_MAX) {
        return false;
    }
    memcpy(id, request_id, sizeof(id));
    requested_operation = operation_text;
    requested_target    = target_text;
    request_payload     = payload;
    return true;
}

const Byte *EffectIntent::request_id() const {
    return id;
}

const String &EffectIntent::operation() const {
    return requested_operation;
}

const String &EffectIntent::target() const {
    return requested_target;
}

const Bytes &EffectIntent::payload() const {
    return request_payload;
}

bool EffectIntent::valid() const {
    return !id_is_zero(id) && valid_name(requested_operation) &&
           valid_name(requested_target) && request_payload.size() <= UINT32_MAX;
}

bool encode_effect_intent(const EffectIntent &intent, Value *value) {
    if (!intent.valid() || value == 0 || intent.operation().size() > UINT32_MAX ||
        intent.target().size() > UINT32_MAX) {
        return false;
    }
    Bytes bytes;
    bytes.insert(bytes.end(), INTENT_MAGIC, INTENT_MAGIC + sizeof(INTENT_MAGIC));
    write_u32(&bytes, EFFECT_VERSION);
    bytes.insert(bytes.end(), intent.request_id(),
                 intent.request_id() + EffectIntent::REQUEST_ID_SIZE);
    write_u32(&bytes, static_cast<U32>(intent.operation().size()));
    bytes.insert(bytes.end(), intent.operation().begin(), intent.operation().end());
    write_u32(&bytes, static_cast<U32>(intent.target().size()));
    bytes.insert(bytes.end(), intent.target().begin(), intent.target().end());
    write_u32(&bytes, static_cast<U32>(intent.payload().size()));
    bytes.insert(bytes.end(), intent.payload().begin(), intent.payload().end());
    *value = Value(bytes);
    return true;
}

bool decode_effect_intent(const Value &value, EffectIntent *intent) {
    if (value.type() != VALUE_BYTES || intent == 0) {
        return false;
    }
    const Bytes &bytes = value.bytes();
    const Size   fixed_size =
        EFFECT_MAGIC_SIZE + 4 + EffectIntent::REQUEST_ID_SIZE + 4 + 4 + 4;
    if (bytes.size() < fixed_size ||
        memcmp(bytes.data(), INTENT_MAGIC, sizeof(INTENT_MAGIC)) != 0) {
        return false;
    }

    Size   offset  = EFFECT_MAGIC_SIZE;
    U32    version = 0;
    Byte   request_id[EffectIntent::REQUEST_ID_SIZE];
    String operation;
    String target;
    Bytes  payload;
    if (!read_u32(bytes, &offset, &version) || version != EFFECT_VERSION ||
        bytes.size() - offset < sizeof(request_id)) {
        return false;
    }
    memcpy(request_id, bytes.data() + offset, sizeof(request_id));
    offset += sizeof(request_id);
    EffectIntent decoded;
    if (!read_string(bytes, &offset, &operation) || !read_string(bytes, &offset, &target) ||
        !read_bytes(bytes, &offset, &payload) || offset != bytes.size() ||
        !decoded.set(request_id, operation.c_str(), target.c_str(), payload)) {
        return false;
    }
    *intent = decoded;
    return true;
}

EffectObservation::EffectObservation() : succeeded(false) {
    memset(id, 0, sizeof(id));
}

bool EffectObservation::set(const Byte *request_id, bool success, const Bytes &bytes) {
    if (id_is_zero(request_id) || bytes.size() > UINT32_MAX) {
        return false;
    }
    memcpy(id, request_id, sizeof(id));
    succeeded         = success;
    observation_bytes = bytes;
    return true;
}

const Byte *EffectObservation::request_id() const {
    return id;
}

bool EffectObservation::success() const {
    return succeeded;
}

const Bytes &EffectObservation::bytes() const {
    return observation_bytes;
}

bool EffectObservation::valid() const {
    return !id_is_zero(id) && observation_bytes.size() <= UINT32_MAX;
}

bool encode_effect_observation(const EffectObservation &observation, Value *value) {
    if (!observation.valid() || value == 0) {
        return false;
    }
    Bytes bytes;
    bytes.insert(bytes.end(), OBSERVATION_MAGIC,
                 OBSERVATION_MAGIC + sizeof(OBSERVATION_MAGIC));
    write_u32(&bytes, EFFECT_VERSION);
    bytes.insert(bytes.end(), observation.request_id(),
                 observation.request_id() + EffectIntent::REQUEST_ID_SIZE);
    bytes.push_back(observation.success() ? 1 : 0);
    write_u32(&bytes, static_cast<U32>(observation.bytes().size()));
    bytes.insert(bytes.end(), observation.bytes().begin(), observation.bytes().end());
    *value = Value(bytes);
    return true;
}

bool decode_effect_observation(const Value &value, EffectObservation *observation) {
    if (value.type() != VALUE_BYTES || observation == 0) {
        return false;
    }
    const Bytes &bytes      = value.bytes();
    const Size   fixed_size = EFFECT_MAGIC_SIZE + 4 + EffectIntent::REQUEST_ID_SIZE + 1 + 4;
    if (bytes.size() < fixed_size ||
        memcmp(bytes.data(), OBSERVATION_MAGIC, sizeof(OBSERVATION_MAGIC)) != 0) {
        return false;
    }

    Size offset  = EFFECT_MAGIC_SIZE;
    U32  version = 0;
    Byte request_id[EffectIntent::REQUEST_ID_SIZE];
    if (!read_u32(bytes, &offset, &version) || version != EFFECT_VERSION ||
        bytes.size() - offset < sizeof(request_id) + 1) {
        return false;
    }
    memcpy(request_id, bytes.data() + offset, sizeof(request_id));
    offset += sizeof(request_id);
    const Byte        success = bytes[offset++];
    Bytes             result;
    EffectObservation decoded;
    if (success > 1 || !read_bytes(bytes, &offset, &result) || offset != bytes.size() ||
        !decoded.set(request_id, success == 1, result)) {
        return false;
    }
    *observation = decoded;
    return true;
}

EffectExecutor::~EffectExecutor() {}

bool EffectExecutorRegistry::put(const char *operation, EffectExecutor *executor) {
    if (operation == 0 || executor == 0) {
        return false;
    }
    const String name(operation);
    if (!valid_name(name)) {
        return false;
    }
    executors[name] = executor;
    return true;
}

bool EffectExecutorRegistry::get(const char *operation, EffectExecutor **executor) const {
    if (operation == 0 || executor == 0) {
        return false;
    }
    EffectExecutorTable::const_iterator found = executors.find(operation);
    if (found == executors.end()) {
        return false;
    }
    *executor = found->second;
    return true;
}

EffectBoundaryResult::EffectBoundaryResult()
    : boundary_code(EFFECT_INVALID_ARGUMENT), observation_present(false) {}

EffectBoundaryCode EffectBoundaryResult::code() const {
    return boundary_code;
}

const String &EffectBoundaryResult::message() const {
    return boundary_message;
}

bool EffectBoundaryResult::has_observation() const {
    return observation_present;
}

const EffectObservation &EffectBoundaryResult::observation() const {
    return effect_observation;
}

bool EffectBoundaryResult::succeeded() const {
    return boundary_code == EFFECT_PERFORMED || boundary_code == EFFECT_REPLAYED;
}

bool effect_observation_id(const Byte *request_id, TexelId *id) {
    if (id_is_zero(request_id) || id == 0) {
        return false;
    }
    id->set_bytes(request_id);
    return true;
}

bool make_effect_texel(const TexelId &id, const EffectIntent &intent, Texel *texel) {
    if (id.is_unset() || !intent.valid() || texel == 0) {
        return false;
    }
    Value value;
    if (!encode_effect_intent(intent, &value)) {
        return false;
    }
    OutputPort output("intent", VALUE_BYTES);
    if (!output.set_source(value)) {
        return false;
    }
    Texel made(id);
    if (!made.put_output(output) || !made.put_input(InputPort("capability", VALUE_BYTES))) {
        return false;
    }
    *texel = made;
    return true;
}

bool make_capability_texel(const TexelId &id, const Capability &capability, Texel *texel) {
    if (id.is_unset() || texel == 0) {
        return false;
    }
    Value value;
    if (!encode_capability(capability, &value)) {
        return false;
    }
    OutputPort output("capability", VALUE_BYTES);
    if (!output.set_source(value)) {
        return false;
    }
    Texel made(id);
    if (!made.put_output(output)) {
        return false;
    }
    *texel = made;
    return true;
}

EffectBoundary::EffectBoundary(Store *effect_store, Spool *effect_spool,
                               const Authority              *effect_authority,
                               const EffectExecutorRegistry *executor_registry)
    : store(effect_store), spool(effect_spool), authority(effect_authority),
      registry(executor_registry) {}

EffectBoundaryResult EffectBoundary::error(EffectBoundaryCode code,
                                           const char        *message) const {
    EffectBoundaryResult result;
    result.boundary_code    = code;
    result.boundary_message = message != 0 ? message : "";
    return result;
}

EffectBoundaryResult EffectBoundary::receipt(const EffectObservation &observation,
                                             EffectBoundaryCode       code) const {
    EffectBoundaryResult result;
    result.boundary_code       = code;
    result.observation_present = true;
    result.effect_observation  = observation;
    return result;
}

EffectBoundaryResult EffectBoundary::perform(const TexelId &effect) {
    if (store == 0 || spool == 0 || authority == 0 || registry == 0 || effect.is_unset() ||
        !store->is_open()) {
        return error(EFFECT_INVALID_ARGUMENT, "invalid effect boundary");
    }

    Texel effect_texel;
    if (!store->get(effect, &effect_texel)) {
        return error(EFFECT_MISSING_EFFECT, "effect texel is missing");
    }
    OutputPort intent_port;
    InputPort  capability_port;
    if (!effect_texel.get_output("intent", &intent_port) ||
        intent_port.type() != VALUE_BYTES ||
        !effect_texel.get_input("capability", &capability_port) ||
        capability_port.type() != VALUE_BYTES) {
        return error(EFFECT_MALFORMED_EFFECT, "effect port shape is invalid");
    }

    ValueOutcome intent_outcome;
    const Value *intent_value = 0;
    if (!spool->demand(effect, "intent", &intent_outcome) ||
        intent_outcome.status() == VALUE_UNAVAILABLE) {
        return error(EFFECT_MISSING_INTENT, "effect intent is unavailable");
    }
    if (!available_bytes(intent_outcome, &intent_value)) {
        return error(EFFECT_MALFORMED_INTENT, "effect intent demand failed");
    }
    EffectIntent intent;
    if (!decode_effect_intent(*intent_value, &intent)) {
        return error(EFFECT_MALFORMED_INTENT, "effect intent is malformed");
    }

    TexelId observation_id;
    effect_observation_id(intent.request_id(), &observation_id);
    if (store->has(observation_id)) {
        EffectObservation observation;
        if (!load_observation(store, observation_id, &observation) ||
            !same_request(intent.request_id(), observation.request_id())) {
            return error(EFFECT_MALFORMED_RECEIPT, "stored effect receipt is malformed");
        }
        return receipt(observation, EFFECT_REPLAYED);
    }

    if (!capability_port.has_binding()) {
        return error(EFFECT_MISSING_CAPABILITY, "effect capability is not connected");
    }
    const Fiber &binding = capability_port.binding();
    ValueOutcome capability_outcome;
    const Value *capability_value = 0;
    if (!spool->demand(binding.source(), binding.output().c_str(), &capability_outcome) ||
        capability_outcome.status() == VALUE_UNAVAILABLE) {
        return error(EFFECT_MISSING_CAPABILITY, "effect capability is unavailable");
    }
    if (!available_bytes(capability_outcome, &capability_value)) {
        return error(EFFECT_MALFORMED_CAPABILITY, "effect capability demand failed");
    }
    Capability capability;
    if (!decode_capability(*capability_value, &capability)) {
        return error(EFFECT_MALFORMED_CAPABILITY, "effect capability is malformed");
    }
    if (!authority->verify(capability, intent.operation().c_str(),
                           intent.target().c_str())) {
        return error(EFFECT_CAPABILITY_DENIED, "effect capability does not grant intent");
    }

    EffectExecutor *executor = 0;
    if (!registry->get(intent.operation().c_str(), &executor)) {
        return error(EFFECT_MISSING_EXECUTOR, "effect executor is not registered");
    }
    EffectObservation observation;
    if (!executor->perform(intent, &observation)) {
        return error(EFFECT_EXECUTOR_FAILED, "effect executor failed");
    }
    if (!observation.valid() ||
        !same_request(intent.request_id(), observation.request_id())) {
        return error(EFFECT_INVALID_OBSERVATION,
                     "effect executor returned an invalid observation");
    }

    Value      observation_value;
    OutputPort observation_output("observation", VALUE_BYTES);
    Texel      observation_texel(observation_id);
    if (!encode_effect_observation(observation, &observation_value) ||
        !observation_output.set_source(observation_value) ||
        !observation_texel.put_output(observation_output)) {
        return error(EFFECT_INVALID_OBSERVATION, "effect observation could not be encoded");
    }

    Transaction transaction;
    if (!store->begin(&transaction) || !transaction.put(observation_texel) ||
        !transaction.commit()) {
        if (transaction.is_active()) {
            transaction.abort();
        }
        return error(EFFECT_STORE_FAILED, "effect observation could not be persisted");
    }
    return receipt(observation, EFFECT_PERFORMED);
}

} // namespace lucia
