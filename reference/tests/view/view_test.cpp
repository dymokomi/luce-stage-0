#include <stdio.h>

#include "fabric/persistence/store.h"
#include "storage/volume/memory_volume.h"
#include "view/runtime/evaluators.h"
#include "view/runtime/shell.h"

using namespace lucia;

static int failures = 0;

#define CHECK(condition)                                                                   \
    do {                                                                                   \
        if (!(condition)) {                                                                \
            fprintf(stderr, "fail: %s (%s:%d)\n", #condition, __FILE__, __LINE__);         \
            ++failures;                                                                    \
        }                                                                                  \
    } while (0)

static Texel text_source(const char *text) {
    TexelId id;
    id.generate();

    Texel      texel(id);
    OutputPort output("text", VALUE_TEXT);
    output.set_source(Value(text));
    texel.put_output(output);
    return texel;
}

static void check_interfaces(Shell *shell, const TexelId &prose, const TexelId &table,
                             const char *text) {
    String rendered;
    CHECK(shell->interface(prose, &rendered));
    CHECK(rendered == String("body: ") + text);

    CHECK(shell->interface(table, &rendered));
    CHECK(rendered.find("| Field | Value") != String::npos);
    CHECK(rendered.find(String("| body  | ") + text) != String::npos);
    CHECK(rendered.find("body:") == String::npos);
}

static void test_views_share_source() {
    MemoryVolume volume(32);
    Store        store;
    CHECK(store.create(&volume));

    Texel         source    = text_source("alpha");
    const TexelId source_id = source.id();

    TexelId prose_id;
    TexelId table_id;
    CHECK(prose_id.generate());
    CHECK(table_id.generate());

    Strings inputs;
    inputs.push_back("body");
    Texel prose;
    Texel table;
    CHECK(make_prose_view(prose_id, inputs, &prose));
    CHECK(make_table_view(table_id, inputs, &table));
    CHECK(prose.id().equals(prose_id));
    CHECK(table.id().equals(table_id));
    CHECK(prose.evaluator() == PROSE_VIEW_EVALUATOR);
    CHECK(table.evaluator() == TABLE_VIEW_EVALUATOR);

    Transaction transaction;
    CHECK(store.begin(&transaction));
    CHECK(transaction.put(source));
    CHECK(transaction.put(prose));
    CHECK(transaction.put(table));
    CHECK(transaction.connect(prose.id(), "body", source.id(), "text"));
    CHECK(transaction.connect(table.id(), "body", source.id(), "text"));
    CHECK(transaction.commit());

    Shell shell(&store);
    CHECK(shell.is_ready());
    CHECK(shell.add(prose.id(), "Article"));
    CHECK(shell.add(table.id(), "Data table"));
    CHECK(shell.size() == 2);

    Strings labels;
    CHECK(shell.accessibility_labels(&labels));
    CHECK(labels.size() == 2);
    CHECK(labels[0] == "Article");
    CHECK(labels[1] == "Data table");

    check_interfaces(&shell, prose.id(), table.id(), "alpha");

    String frame;
    CHECK(shell.compose(&frame));
    CHECK(frame.find("[Article]\nbody: alpha") != String::npos);
    CHECK(frame.find("[Data table]\n+-------+") != String::npos);
    CHECK(frame.find("[Article]") < frame.find("[Data table]"));

    CHECK(shell.focus(0));
    CHECK(shell.edit(source_id, "text", "beta"));
    check_interfaces(&shell, prose.id(), table.id(), "beta");

    Size focus = 9;
    CHECK(shell.focus(1));
    CHECK(shell.focused(&focus));
    CHECK(focus == 1);
    CHECK(shell.edit(source_id, "text", "gamma"));
    check_interfaces(&shell, prose.id(), table.id(), "gamma");

    Texel persisted_source;
    CHECK(store.get(source_id, &persisted_source));
    CHECK(persisted_source.id().equals(source_id));

    Store reopened;
    CHECK(reopened.open(&volume));
    Shell reopened_shell(&reopened);
    CHECK(reopened_shell.add(prose_id, "Article"));
    CHECK(reopened_shell.add(table_id, "Data table"));
    check_interfaces(&reopened_shell, prose_id, table_id, "gamma");
    CHECK(reopened_shell.compose(&frame));
    CHECK(frame.find("body: gamma") != String::npos);
    CHECK(frame.find("| body  | gamma") != String::npos);
}

int main() {
    test_views_share_source();

    if (failures != 0) {
        fprintf(stderr, "%d checks failed\n", failures);
        return 1;
    }
    printf("ok\n");
    return 0;
}
