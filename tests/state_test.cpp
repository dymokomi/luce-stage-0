#include <stdio.h>

#include "fabric/store.h"
#include "loom/spool.h"
#include "loom/state.h"
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

class IncrementEvaluator : public Evaluator {
public:
  IncrementEvaluator()
      : calls(0),
        available(true)
  {
  }

  void evaluate(const Texel&, const ValueOutcomeMap& inputs,
                ValueOutcomeMap* outputs) override
  {
    ++calls;
    ValueOutcomeMap::const_iterator input = inputs.find("input");
    if (!available || input == inputs.end() ||
        input->second.status() != VALUE_AVAILABLE) {
      (*outputs)["value"] = ValueOutcome::unavailable();
      return;
    }
    (*outputs)["value"] =
        ValueOutcome::available(Value(input->second.value().integer() + 1));
  }

  int  calls;
  bool available;
};

static Texel increment_texel()
{
  TexelId id;
  id.generate();
  Texel texel(id);
  texel.set_evaluator("increment");
  texel.put_input(InputPort("input", VALUE_INT));
  texel.put_output(OutputPort("value", VALUE_INT));
  return texel;
}

static Texel copy_texel()
{
  TexelId id;
  id.generate();
  Texel texel(id);
  texel.set_evaluator("copy");
  texel.put_input(InputPort("input", VALUE_INT));
  texel.put_output(OutputPort("value", VALUE_INT));
  return texel;
}

static void check_integer(Spool* spool, const TexelId& id, S64 expected)
{
  ValueOutcome outcome;
  CHECK(spool->demand(id, "value", &outcome));
  CHECK(outcome.status() == VALUE_AVAILABLE);
  if (outcome.status() == VALUE_AVAILABLE) {
    CHECK(outcome.value().type() == VALUE_INT);
    CHECK(outcome.value().integer() == expected);
  }
}

static void test_state_feedback_and_reopen()
{
  MemoryVolume volume(32);
  Store store;
  CHECK(store.create(&volume));

  TexelId state_id;
  CHECK(state_id.generate());
  Texel state;
  CHECK(create_state(state_id, VALUE_INT, Value(0), &state));
  Texel increment = increment_texel();

  Transaction transaction;
  CHECK(store.begin(&transaction));
  CHECK(transaction.put(state));
  CHECK(transaction.put(increment));
  CHECK(transaction.connect(increment.id(), "input", state.id(), "value"));
  CHECK(transaction.connect(state.id(), "next", increment.id(), "value"));
  CHECK(transaction.commit());

  IncrementEvaluator evaluator;
  EvaluatorRegistry registry;
  CHECK(registry.put("increment", &evaluator));
  Spool spool(&store, &registry);
  TemporalRuntime runtime;

  check_integer(&spool, state.id(), 0);
  check_integer(&spool, state.id(), 0);
  CHECK(evaluator.calls == 0);

  String error;
  CHECK(runtime.advance(&store, &spool, state.id(), &error));
  CHECK(error.empty());
  CHECK(evaluator.calls == 1);
  check_integer(&spool, state.id(), 1);
  check_integer(&spool, state.id(), 1);

  CHECK(runtime.advance(&store, &spool, state.id(), &error));
  CHECK(evaluator.calls == 2);
  check_integer(&spool, state.id(), 2);

  evaluator.available = false;
  const U64 generation = store.generation();
  CHECK(!runtime.advance(&store, &spool, state.id(), &error));
  CHECK(!error.empty());
  CHECK(store.generation() == generation);
  check_integer(&spool, state.id(), 2);

  Store reopened;
  CHECK(reopened.open(&volume));
  Spool reopened_spool(&reopened, 0);
  check_integer(&reopened_spool, state.id(), 2);
}

static void test_ordinary_cycle_rejected()
{
  MemoryVolume volume(32);
  Store store;
  CHECK(store.create(&volume));

  Texel first = copy_texel();
  Texel second = copy_texel();
  Transaction transaction;
  CHECK(store.begin(&transaction));
  CHECK(transaction.put(first));
  CHECK(transaction.put(second));
  CHECK(transaction.connect(first.id(), "input", second.id(), "value"));
  CHECK(transaction.connect(second.id(), "input", first.id(), "value"));
  CHECK(!transaction.commit());
  CHECK(transaction.abort());
  CHECK(store.size() == 0);
}

static void test_delay_creation_validation()
{
  TexelId id;
  CHECK(id.generate());

  Texel delay;
  CHECK(create_delay(id, VALUE_TEXT, Value("first"), &delay));
  CHECK(delay.evaluator() == DELAY_EVALUATOR);
  CHECK(delay.input_size() == 1);
  CHECK(delay.output_size() == 1);

  InputPort next;
  OutputPort value;
  CHECK(delay.get_input("next", &next));
  CHECK(delay.get_output("value", &value));
  CHECK(next.type() == VALUE_TEXT);
  CHECK(value.type() == VALUE_TEXT);
  CHECK(value.has_source());
  CHECK(value.source().text() == "first");

  Texel rejected;
  CHECK(!create_delay(id, VALUE_NONE, Value("first"), &rejected));
  CHECK(!create_delay(id, VALUE_INT, Value("first"), &rejected));

  TexelId unset;
  CHECK(!create_delay(unset, VALUE_TEXT, Value("first"), &rejected));
  CHECK(!create_delay(id, VALUE_TEXT, Value(), &rejected));
  CHECK(!create_delay(id, VALUE_TEXT, Value("first"), 0));
}

int main()
{
  test_state_feedback_and_reopen();
  test_ordinary_cycle_rejected();
  test_delay_creation_validation();

  if (failures != 0) {
    fprintf(stderr, "%d checks failed\n", failures);
    return 1;
  }
  printf("ok\n");
  return 0;
}
