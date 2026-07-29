#include <stdio.h>

#include "fabric/model/blob_ref.h"
#include "fabric/model/fiber.h"
#include "fabric/model/input_port.h"
#include "fabric/model/output_port.h"
#include "fabric/model/texel.h"
#include "fabric/model/texel_id.h"
#include "fabric/model/value.h"
#include "fabric/model/value_outcome.h"

using namespace lucia;

static int failures = 0;

#define CHECK(condition)                                                                   \
    do {                                                                                   \
        if (!(condition)) {                                                                \
            fprintf(stderr, "fail: %s (%s:%d)\n", #condition, __FILE__, __LINE__);         \
            ++failures;                                                                    \
        }                                                                                  \
    } while (0)

static void test_texel_identity() {
    TexelId id;
    CHECK(id.is_unset());
    CHECK(id.generate());
    CHECK(!id.is_unset());

    const String text = id.format();
    CHECK(text.size() == TexelId::TEXT_SIZE);

    TexelId parsed;
    CHECK(parsed.parse(text.c_str()));
    CHECK(parsed.equals(id));
    CHECK(!parsed.parse("01"));
}

static void test_values_and_outcomes() {
    TexelId id;
    CHECK(id.generate());

    Byte blob_id[BlobRef::ID_SIZE] = {0};
    blob_id[0]                     = 7;
    BlobRef blob(blob_id, 123);

    CHECK(Value(true).type() == VALUE_BOOL);
    CHECK(Value(-2).integer() == -2);
    CHECK(Value(1.5).real() == 1.5);
    CHECK(Value("text").text() == "text");
    CHECK(Value(id).texel().equals(id));
    CHECK(Value(blob).blob().equals(blob));

    ValueOutcome available = ValueOutcome::available(Value("ready"));
    CHECK(available.status() == VALUE_AVAILABLE);
    CHECK(available.value().text() == "ready");

    ValueOutcome unavailable = ValueOutcome::unavailable();
    CHECK(unavailable.status() == VALUE_UNAVAILABLE);

    ValueOutcome error = ValueOutcome::error("broken");
    CHECK(error.status() == VALUE_ERROR);
    CHECK(error.message() == "broken");
}

static void test_typed_ports_and_fiber() {
    TexelId source;
    CHECK(source.generate());

    Fiber fiber(source, "text");
    CHECK(fiber.valid());

    InputPort input("left", VALUE_TEXT);
    CHECK(input.valid());
    CHECK(!input.has_binding());
    CHECK(input.bind(fiber));
    CHECK(input.has_binding());
    CHECK(input.binding().equals(fiber));

    OutputPort output("text", VALUE_TEXT);
    CHECK(output.valid());
    CHECK(!output.has_source());
    CHECK(!output.set_source(Value(3)));
    CHECK(output.set_source(Value("hello")));
    CHECK(output.revision() == 1);
    CHECK(output.source().text() == "hello");
}

static void test_texel() {
    TexelId id;
    CHECK(id.generate());

    Texel source(id);
    CHECK(source.put_output(OutputPort("text", VALUE_TEXT)));
    CHECK(source.valid());

    OutputPort output;
    CHECK(source.get_output("text", &output));
    CHECK(output.set_source(Value("hello")));
    CHECK(source.put_output(output));

    TexelId computed_id;
    CHECK(computed_id.generate());
    Texel computed(computed_id);
    CHECK(computed.set_evaluator("concat"));
    CHECK(computed.set_content(Value("label")));
    CHECK(computed.put_input(InputPort("left", VALUE_TEXT)));
    CHECK(computed.put_output(OutputPort("result", VALUE_TEXT)));
    CHECK(computed.valid());
    CHECK(computed.input_size() == 1);
    CHECK(computed.output_size() == 1);
}

int main() {
    test_texel_identity();
    test_values_and_outcomes();
    test_typed_ports_and_fiber();
    test_texel();

    if (failures != 0) {
        fprintf(stderr, "%d checks failed\n", failures);
        return 1;
    }
    printf("ok\n");
    return 0;
}
