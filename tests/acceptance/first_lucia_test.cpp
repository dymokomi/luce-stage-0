#include <spawn.h>
#include <stdio.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <unistd.h>

#include "fabric/persistence/store.h"
#include "loom/evaluation/spool.h"
#include "loom/organization/arrangement.h"
#include "projection/file/file_projection.h"
#include "storage/volume/file_volume.h"
#include "view/runtime/evaluators.h"
#include "view/runtime/shell.h"

using namespace lucia;

extern char **environ;

static int failures = 0;

#define CHECK(condition)                                                                   \
  do {                                                                                     \
    if (!(condition)) {                                                                    \
      fprintf(stderr, "fail: %s (%s:%d)\n", #condition, __FILE__, __LINE__);               \
      ++failures;                                                                          \
    }                                                                                      \
  } while (0)

class AppendEvaluator : public Evaluator {
public:
  void evaluate(const Texel &, const ValueOutcomeMap &inputs,
                ValueOutcomeMap *outputs) override {
    ValueOutcomeMap::const_iterator body   = inputs.find("body");
    ValueOutcomeMap::const_iterator suffix = inputs.find("suffix");
    if (body == inputs.end() || suffix == inputs.end() ||
        body->second.status() != VALUE_AVAILABLE ||
        suffix->second.status() != VALUE_AVAILABLE) {
      (*outputs)["text"] = ValueOutcome::unavailable();
      return;
    }
    (*outputs)["text"] = ValueOutcome::available(
        Value(body->second.value().text() + suffix->second.value().text()));
  }
};

static TexelId make_id() {
  TexelId id;
  CHECK(id.generate());
  return id;
}

static Texel source(const TexelId &id, const char *text) {
  Texel      texel(id);
  OutputPort output("text", VALUE_TEXT);
  CHECK(output.set_source(Value(text)));
  CHECK(texel.put_output(output));
  return texel;
}

static bool run_sed(const char *path) {
  char *arguments[] = {const_cast<char *>("sed"),
                       const_cast<char *>("-i"),
                       const_cast<char *>(""),
                       const_cast<char *>("-e"),
                       const_cast<char *>("s/view two/tool edit/"),
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

static void check_demand(Store *store, const TexelId &computed, const char *expected) {
  AppendEvaluator   append;
  EvaluatorRegistry registry;
  CHECK(registry.put("proof.append", &append));
  Spool        spool(store, &registry);
  ValueOutcome outcome;
  CHECK(spool.demand(computed, "text", &outcome));
  CHECK(outcome.status() == VALUE_AVAILABLE);
  if (outcome.status() == VALUE_AVAILABLE) {
    CHECK(outcome.value().text() == expected);
  }
}

static void check_views(Store *store, const TexelId &prose, const TexelId &table,
                        const char *text) {
  Shell shell(store);
  CHECK(shell.add(prose, "Prose"));
  CHECK(shell.add(table, "Table"));
  String frame;
  CHECK(shell.compose(&frame));
  CHECK(frame.find(text) != String::npos);
  CHECK(frame.find("body:") != String::npos);
  CHECK(frame.find("| Field |") != String::npos);
}

static void test_first_lucia_proof() {
  char  temporary[] = "/tmp/lucia-proof-XXXXXX";
  char *base        = mkdtemp(temporary);
  CHECK(base != 0);
  if (base == 0) {
    return;
  }

  const String image = String(base) + "/loom.img";
  const String root  = String(base) + "/projection";
  const String file  = root + "/material.txt";
  CHECK(mkdir(root.c_str(), 0700) == 0);

  const TexelId material_id       = make_id();
  const TexelId suffix_id         = make_id();
  const TexelId computed_id       = make_id();
  const TexelId first_context_id  = make_id();
  const TexelId second_context_id = make_id();
  const TexelId prose_id          = make_id();
  const TexelId table_id          = make_id();

  if (true) {
    FileVolume volume;
    CHECK(volume.create(image.c_str(), 256));
    Store store;
    CHECK(store.create(&volume));

    Texel material = source(material_id, "original text");
    Texel suffix   = source(suffix_id, "!");

    Texel computed(computed_id);
    CHECK(computed.set_evaluator("proof.append"));
    CHECK(computed.put_input(InputPort("body", VALUE_TEXT)));
    CHECK(computed.put_input(InputPort("suffix", VALUE_TEXT)));
    CHECK(computed.put_output(OutputPort("text", VALUE_TEXT)));

    Texel first_context;
    Texel second_context;
    CHECK(create_arrangement(first_context_id, &first_context));
    CHECK(create_arrangement(second_context_id, &second_context));
    CHECK(arrangement_add(&first_context, "draft", material_id));
    CHECK(arrangement_add(&second_context, "published", material_id));

    Strings view_inputs;
    view_inputs.push_back("body");
    Texel prose;
    Texel table;
    CHECK(make_prose_view(prose_id, view_inputs, &prose));
    CHECK(make_table_view(table_id, view_inputs, &table));

    Transaction transaction;
    CHECK(store.begin(&transaction));
    CHECK(transaction.put(material));
    CHECK(transaction.put(suffix));
    CHECK(transaction.put(computed));
    CHECK(transaction.put(first_context));
    CHECK(transaction.put(second_context));
    CHECK(transaction.put(prose));
    CHECK(transaction.put(table));
    CHECK(transaction.connect(computed_id, "body", material_id, "text"));
    CHECK(transaction.connect(computed_id, "suffix", suffix_id, "text"));
    CHECK(transaction.connect(prose_id, "body", material_id, "text"));
    CHECK(transaction.connect(table_id, "body", material_id, "text"));
    CHECK(transaction.commit());

    check_demand(&store, computed_id, "original text!");

    Shell shell(&store);
    CHECK(shell.add(prose_id, "Prose"));
    CHECK(shell.add(table_id, "Table"));
    CHECK(shell.focus(0));
    CHECK(shell.edit(material_id, "text", "view one"));
    CHECK(shell.focus(1));
    CHECK(shell.edit(material_id, "text", "view two"));
    check_views(&store, prose_id, table_id, "view two");

    ProjectionManifest manifest;
    CHECK(manifest.put(ProjectionEntry(material_id, "text", VALUE_TEXT, "material.txt")));
    FileProjection projection;
    CHECK(projection.export_from(store, manifest, root.c_str()));
    CHECK(run_sed(file.c_str()));
    CHECK(projection.import_changes(&store));
    check_demand(&store, computed_id, "tool edit!");
    check_views(&store, prose_id, table_id, "tool edit");
  }

  if (true) {
    FileVolume volume;
    CHECK(volume.open(image.c_str()));
    Store store;
    CHECK(store.open(&volume));

    Texel material;
    Texel first_context;
    Texel second_context;
    CHECK(store.get(material_id, &material));
    CHECK(material.id().equals(material_id));
    CHECK(store.get(first_context_id, &first_context));
    CHECK(store.get(second_context_id, &second_context));
    CHECK(validate_arrangement(first_context, store));
    CHECK(validate_arrangement(second_context, store));

    ArrangementEntries first_entries;
    ArrangementEntries second_entries;
    CHECK(inspect_arrangement(first_context, &first_entries));
    CHECK(inspect_arrangement(second_context, &second_entries));
    CHECK(first_entries.size() == 1);
    CHECK(second_entries.size() == 1);
    CHECK(first_entries[0].name == "draft");
    CHECK(second_entries[0].name == "published");
    CHECK(first_entries[0].texel.equals(material_id));
    CHECK(second_entries[0].texel.equals(material_id));

    check_demand(&store, computed_id, "tool edit!");
    check_views(&store, prose_id, table_id, "tool edit");
  }

  CHECK(unlink(file.c_str()) == 0);
  CHECK(rmdir(root.c_str()) == 0);
  CHECK(unlink(image.c_str()) == 0);
  CHECK(rmdir(base) == 0);
}

int main() {
  test_first_lucia_proof();
  if (failures != 0) {
    fprintf(stderr, "%d checks failed\n", failures);
    return 1;
  }
  printf("ok\n");
  return 0;
}
