#include <stdio.h>
#include <string.h>

#include "loom/effect.h"
#include "storage/memory_volume.h"

using namespace lucia;

static int failures = 0;

#define CHECK(condition)                                                     \
  do {                                                                       \
    if (!(condition)) {                                                      \
      fprintf(stderr, "fail: %s (%s:%d)\n", #condition, __FILE__, __LINE__); \
      ++failures;                                                            \
    }                                                                        \
  } while (0)

class RecordingExecutor : public EffectExecutor {
public:
  RecordingExecutor()
      : calls(0),
        actions(0),
        has_request(false)
  {
    memset(request, 0, sizeof(request));
  }

  bool perform(const EffectIntent& intent,
               EffectObservation* observation) override
  {
    ++calls;
    if (!has_request) {
      memcpy(request, intent.request_id(), sizeof(request));
      stored = Bytes();
      stored.push_back('o');
      stored.push_back('k');
      ++actions;
      has_request = true;
    } else if (memcmp(request, intent.request_id(), sizeof(request)) != 0) {
      return false;
    }
    return observation->set(intent.request_id(), true, stored);
  }

  int  calls;
  int  actions;
  bool has_request;
  Byte request[EffectIntent::REQUEST_ID_SIZE];
  Bytes stored;
};

static void request_id(Byte seed, Byte* id)
{
  for (Size i = 0; i < EffectIntent::REQUEST_ID_SIZE; ++i) {
    id[i] = static_cast<Byte>(seed + i);
  }
}

static EffectIntent intent(Byte seed, const char* target)
{
  Byte id[EffectIntent::REQUEST_ID_SIZE];
  request_id(seed, id);
  Bytes payload;
  payload.push_back(0x10);
  payload.push_back(0x20);
  EffectIntent value;
  CHECK(value.set(id, "write", target, payload));
  return value;
}

static TexelId new_id()
{
  TexelId id;
  CHECK(id.generate());
  return id;
}

static bool put_effect(Store* store, const Texel& effect,
                       const Texel* capability)
{
  Transaction transaction;
  if (!store->begin(&transaction) || !transaction.put(effect)) {
    return false;
  }
  if (capability != 0 &&
      (!transaction.put(*capability) ||
       !transaction.connect(effect.id(), "capability", capability->id(),
                            "capability"))) {
    transaction.abort();
    return false;
  }
  return transaction.commit();
}

static void test_capability_and_effect_encoding()
{
  Authority authority;
  Capability capability;
  CHECK(authority.issue("write", "/device/one", &capability));

  Value encoded_capability;
  CHECK(encode_capability(capability, &encoded_capability));
  Capability decoded_capability;
  CHECK(decode_capability(encoded_capability, &decoded_capability));
  CHECK(authority.verify(decoded_capability, "write", "/device/one"));

  Bytes malformed = encoded_capability.bytes();
  malformed.push_back(0);
  CHECK(!decode_capability(Value(malformed), &decoded_capability));
  malformed = encoded_capability.bytes();
  malformed.resize(malformed.size() - 1);
  CHECK(!decode_capability(Value(malformed), &decoded_capability));
  CHECK(!decode_capability(Value("not bytes"), &decoded_capability));

  EffectIntent original = intent(1, "/device/one");
  Value encoded_intent;
  CHECK(encode_effect_intent(original, &encoded_intent));
  EffectIntent decoded_intent;
  CHECK(decode_effect_intent(encoded_intent, &decoded_intent));
  CHECK(memcmp(original.request_id(), decoded_intent.request_id(),
               EffectIntent::REQUEST_ID_SIZE) == 0);
  CHECK(decoded_intent.operation() == "write");
  CHECK(decoded_intent.target() == "/device/one");
  CHECK(decoded_intent.payload() == original.payload());

  malformed = encoded_intent.bytes();
  malformed[0] = 0;
  CHECK(!decode_effect_intent(Value(malformed), &decoded_intent));
  malformed = encoded_intent.bytes();
  malformed.push_back(0);
  CHECK(!decode_effect_intent(Value(malformed), &decoded_intent));

  Bytes error;
  error.push_back('e');
  EffectObservation original_observation;
  CHECK(original_observation.set(original.request_id(), false, error));
  Value encoded_observation;
  CHECK(encode_effect_observation(original_observation,
                                  &encoded_observation));
  EffectObservation decoded_observation;
  CHECK(decode_effect_observation(encoded_observation,
                                  &decoded_observation));
  CHECK(!decoded_observation.success());
  CHECK(decoded_observation.bytes() == error);

  malformed = encoded_observation.bytes();
  malformed[12 + EffectIntent::REQUEST_ID_SIZE] = 2;
  CHECK(!decode_effect_observation(Value(malformed),
                                   &decoded_observation));
  malformed = encoded_observation.bytes();
  malformed.resize(malformed.size() - 1);
  CHECK(!decode_effect_observation(Value(malformed),
                                   &decoded_observation));
}

static void test_boundary_authority_and_durable_receipt()
{
  MemoryVolume volume(64);
  Store store;
  CHECK(store.create(&volume));

  Authority authority;
  Capability correct;
  Capability wrong;
  CHECK(authority.issue("write", "/device/one", &correct));
  CHECK(authority.issue("write", "/device/two", &wrong));

  RecordingExecutor executor;
  EffectExecutorRegistry executors;
  CHECK(executors.put("write", &executor));
  EvaluatorRegistry evaluators;
  Spool spool(&store, &evaluators);
  EffectBoundary boundary(&store, &spool, &authority, &executors);

  Texel no_capability;
  CHECK(make_effect_texel(new_id(), intent(10, "/device/one"),
                          &no_capability));
  CHECK(put_effect(&store, no_capability, 0));
  EffectBoundaryResult result = boundary.perform(no_capability.id());
  CHECK(result.code() == EFFECT_MISSING_CAPABILITY);
  CHECK(!result.has_observation());
  CHECK(executor.calls == 0);

  Texel wrong_effect;
  Texel wrong_capability;
  CHECK(make_effect_texel(new_id(), intent(50, "/device/one"),
                          &wrong_effect));
  CHECK(make_capability_texel(new_id(), wrong, &wrong_capability));
  CHECK(put_effect(&store, wrong_effect, &wrong_capability));
  result = boundary.perform(wrong_effect.id());
  CHECK(result.code() == EFFECT_CAPABILITY_DENIED);
  CHECK(executor.calls == 0);

  EffectIntent correct_intent = intent(90, "/device/one");
  Texel correct_effect;
  Texel correct_capability;
  CHECK(make_effect_texel(new_id(), correct_intent, &correct_effect));
  CHECK(make_capability_texel(new_id(), correct, &correct_capability));
  CHECK(put_effect(&store, correct_effect, &correct_capability));

  result = boundary.perform(correct_effect.id());
  CHECK(result.code() == EFFECT_PERFORMED);
  CHECK(result.succeeded());
  CHECK(result.has_observation());
  CHECK(result.observation().success());
  CHECK(executor.calls == 1);
  CHECK(executor.actions == 1);

  TexelId observation_id;
  CHECK(effect_observation_id(correct_intent.request_id(),
                              &observation_id));
  CHECK(store.has(observation_id));
  const Bytes first_bytes = result.observation().bytes();

  result = boundary.perform(correct_effect.id());
  CHECK(result.code() == EFFECT_REPLAYED);
  CHECK(result.observation().bytes() == first_bytes);
  CHECK(executor.calls == 1);

  spool.clear();
  result = boundary.perform(correct_effect.id());
  CHECK(result.code() == EFFECT_REPLAYED);
  CHECK(result.observation().bytes() == first_bytes);
  CHECK(executor.calls == 1);

  Store reopened;
  CHECK(reopened.open(&volume));
  Spool reopened_spool(&reopened, &evaluators);
  EffectBoundary reopened_boundary(&reopened, &reopened_spool, &authority,
                                   &executors);
  result = reopened_boundary.perform(correct_effect.id());
  CHECK(result.code() == EFFECT_REPLAYED);
  CHECK(result.observation().bytes() == first_bytes);
  CHECK(executor.calls == 1);
  CHECK(executor.actions == 1);
}

int main()
{
  test_capability_and_effect_encoding();
  test_boundary_authority_and_durable_receipt();

  if (failures != 0) {
    fprintf(stderr, "%d checks failed\n", failures);
    return 1;
  }
  printf("ok\n");
  return 0;
}
