#include "loom/evaluation/spool.h"

#include <limits>

namespace lucia {

namespace {

String endpoint_text(const TexelId &texel, const String &output) {
  return texel.format() + ":" + output;
}

String error_text(const char *message, const TexelId &texel, const String &output) {
  return String(message) + endpoint_text(texel, output);
}

bool same_revisions(const RevisionList &left, const RevisionList &right) {
  if (left.size() != right.size()) {
    return false;
  }
  for (Size i = 0; i < left.size(); ++i) {
    if (left[i] != right[i]) {
      return false;
    }
  }
  return true;
}

bool temporal_evaluator(const String &evaluator) {
  return evaluator == "loom.state" || evaluator == "loom.delay";
}

} // namespace

Evaluator::~Evaluator() {}

bool EvaluatorRegistry::put(const char *name, Evaluator *evaluator) {
  if (name == 0 || name[0] == '\0' || evaluator == 0) {
    return false;
  }

  if (evaluators.find(name) != evaluators.end()) {
    return false;
  }
  evaluators[name] = evaluator;
  return true;
}

bool EvaluatorRegistry::get(const char *name, Evaluator **evaluator) const {
  if (name == 0 || name[0] == '\0' || evaluator == 0) {
    return false;
  }

  EvaluatorTable::const_iterator found = evaluators.find(name);
  if (found == evaluators.end()) {
    return false;
  }
  *evaluator = found->second;
  return true;
}

Size EvaluatorRegistry::size() const {
  return evaluators.size();
}

Spool::Spool(const Store *fabric_store, const EvaluatorRegistry *evaluator_registry)
    : store(fabric_store), registry(evaluator_registry), next_revision(1) {}

bool Spool::Endpoint::operator<(const Endpoint &other) const {
  if (texel.less_than(other.texel)) {
    return true;
  }
  if (other.texel.less_than(texel)) {
    return false;
  }
  return output < other.output;
}

bool Spool::demand(const TexelId &texel, const char *output, ValueOutcome *outcome) {
  if (outcome == 0) {
    return false;
  }
  if (texel.is_unset()) {
    *outcome = ValueOutcome::error("demand has unset texel id");
    return true;
  }
  if (output == 0 || output[0] == '\0') {
    *outcome = ValueOutcome::error("demand has empty output name");
    return true;
  }
  if (store == 0) {
    *outcome = ValueOutcome::error("spool has no store");
    return true;
  }
  if (!store->is_open()) {
    *outcome = ValueOutcome::error("spool store is not open");
    return true;
  }

  const U64    generation = store->generation();
  DemandResult result     = demand_internal(texel, String(output), generation);
  *outcome                = result.outcome;
  active.clear();
  return true;
}

void Spool::clear() {
  source_cache.clear();
  compute_cache.clear();
  active.clear();
}

Size Spool::cache_size() const {
  Size                         size   = source_cache.size();
  ComputeCache::const_iterator record = compute_cache.begin();
  for (; record != compute_cache.end(); ++record) {
    size += record->second.outputs.size();
  }
  return size;
}

Spool::DemandResult Spool::demand_internal(const TexelId &texel, const String &output,
                                           U64 generation) {
  Endpoint endpoint;
  endpoint.texel  = texel;
  endpoint.output = output;

  SourceCache::const_iterator source_found = source_cache.find(endpoint);
  if (source_found != source_cache.end() &&
      source_found->second.checked_generation == generation) {
    DemandResult result;
    result.outcome            = source_found->second.output.outcome;
    result.effective_revision = source_found->second.output.effective_revision;
    return result;
  }

  ComputeCache::const_iterator compute_found = compute_cache.find(texel);
  if (compute_found != compute_cache.end() &&
      compute_found->second.checked_generation == generation) {
    CachedOutputMap::const_iterator output_found =
        compute_found->second.outputs.find(output);
    if (output_found != compute_found->second.outputs.end()) {
      DemandResult result;
      result.outcome            = output_found->second.outcome;
      result.effective_revision = output_found->second.effective_revision;
      return result;
    }
  }

  Texel current;
  if (!store->get(texel, &current)) {
    DemandResult result;
    result.outcome =
        ValueOutcome::error(error_text("missing texel ", texel, output).c_str());
    result.effective_revision = 0;
    return result;
  }

  OutputPort declared_output;
  if (!current.get_output(output.c_str(), &declared_output)) {
    DemandResult result;
    result.outcome =
        ValueOutcome::error(error_text("missing output ", texel, output).c_str());
    result.effective_revision = 0;
    return result;
  }

  if (current.evaluator().empty() || temporal_evaluator(current.evaluator())) {
    return demand_source(current, declared_output, generation);
  }

  if (active.find(texel) != active.end()) {
    DemandResult result;
    result.outcome = ValueOutcome::error(
        error_text("recursive demand cycle at ", texel, output).c_str());
    result.effective_revision = 0;
    return result;
  }

  active.insert(texel);
  DemandResult result = demand_computed(current, output, generation);
  active.erase(texel);
  return result;
}

Spool::DemandResult Spool::demand_source(const Texel &texel, const OutputPort &output,
                                         U64 generation) {
  Endpoint endpoint;
  endpoint.texel  = texel.id();
  endpoint.output = output.name();

  SourceCache::iterator found = source_cache.find(endpoint);
  if (found != source_cache.end() && found->second.texel_revision == texel.revision() &&
      found->second.output_revision == output.revision()) {
    found->second.checked_generation = generation;

    DemandResult result;
    result.outcome            = found->second.output.outcome;
    result.effective_revision = found->second.output.effective_revision;
    return result;
  }

  ValueOutcome outcome = ValueOutcome::unavailable();
  if (output.has_source()) {
    if (output.source().type() != output.type()) {
      outcome = ValueOutcome::error(
          error_text("source type mismatch at ", texel.id(), output.name()).c_str());
    } else {
      outcome = ValueOutcome::available(output.source());
    }
  }

  U64 effective_revision = 0;
  if (!next_effective_revision(&effective_revision)) {
    DemandResult result;
    result.outcome            = ValueOutcome::error("spool effective revisions exhausted");
    result.effective_revision = 0;
    return result;
  }

  SourceRecord record;
  record.checked_generation        = generation;
  record.texel_revision            = texel.revision();
  record.output_revision           = output.revision();
  record.output.outcome            = outcome;
  record.output.effective_revision = effective_revision;
  source_cache[endpoint]           = record;

  DemandResult result;
  result.outcome            = outcome;
  result.effective_revision = effective_revision;
  return result;
}

Spool::DemandResult Spool::demand_computed(const Texel &texel, const String &output,
                                           U64 generation) {
  ValueOutcomeMap inputs;
  RevisionList    revisions;
  revisions.reserve(texel.input_size());

  for (Size i = 0; i < texel.input_size(); ++i) {
    InputPort input;
    if (!texel.input_at(i, &input)) {
      return cache_error(texel, output, generation, revisions, "invalid input table");
    }

    if (!input.has_binding()) {
      inputs[input.name()] = ValueOutcome::unavailable();
      revisions.push_back(0);
      continue;
    }

    const Fiber &binding = input.binding();
    Texel        source;
    if (!store->get(binding.source(), &source)) {
      String message = "missing source texel for input " + input.name();
      return cache_error(texel, output, generation, revisions, message);
    }

    OutputPort source_output;
    if (!source.get_output(binding.output().c_str(), &source_output)) {
      String message = "missing source output for input " + input.name();
      return cache_error(texel, output, generation, revisions, message);
    }
    if (source_output.type() != input.type()) {
      String message = "input type mismatch at " + endpoint_text(texel.id(), input.name());
      return cache_error(texel, output, generation, revisions, message);
    }

    DemandResult upstream = demand_internal(binding.source(), binding.output(), generation);
    inputs[input.name()]  = upstream.outcome;
    revisions.push_back(upstream.effective_revision);
    if (upstream.outcome.status() == VALUE_ERROR) {
      return cache_error(texel, output, generation, revisions, upstream.outcome.message());
    }
  }

  ComputeCache::iterator found = compute_cache.find(texel.id());
  if (found != compute_cache.end() && found->second.texel_revision == texel.revision() &&
      same_revisions(found->second.input_revisions, revisions)) {
    CachedOutputMap::const_iterator cached = found->second.outputs.find(output);
    if (cached != found->second.outputs.end()) {
      found->second.checked_generation = generation;

      DemandResult result;
      result.outcome            = cached->second.outcome;
      result.effective_revision = cached->second.effective_revision;
      return result;
    }
  }

  return evaluate(texel, output, generation, inputs, revisions);
}

Spool::DemandResult Spool::evaluate(const Texel &texel, const String &output,
                                    U64 generation, const ValueOutcomeMap &inputs,
                                    const RevisionList &revisions) {
  Evaluator *evaluator = 0;
  if (registry == 0 || !registry->get(texel.evaluator().c_str(), &evaluator)) {
    String message = "missing evaluator " + texel.evaluator();
    return cache_error(texel, output, generation, revisions, message);
  }

  ValueOutcomeMap evaluated;
  evaluator->evaluate(texel, inputs, &evaluated);

  ValueOutcomeMap::const_iterator returned = evaluated.begin();
  for (; returned != evaluated.end(); ++returned) {
    OutputPort declared;
    if (!texel.get_output(returned->first.c_str(), &declared)) {
      String message = "evaluator returned unknown output " + returned->first;
      return cache_error(texel, output, generation, revisions, message);
    }
    if (returned->second.status() == VALUE_AVAILABLE &&
        returned->second.value().type() != declared.type()) {
      String message =
          "evaluator output type mismatch at " + endpoint_text(texel.id(), returned->first);
      return cache_error(texel, output, generation, revisions, message);
    }
  }

  for (Size i = 0; i < texel.output_size(); ++i) {
    OutputPort declared;
    if (!texel.output_at(i, &declared)) {
      return cache_error(texel, output, generation, revisions, "invalid output table");
    }
    if (evaluated.find(declared.name()) == evaluated.end()) {
      String message = "evaluator omitted output " + declared.name();
      return cache_error(texel, output, generation, revisions, message);
    }
  }

  ComputeRecord record;
  record.checked_generation = generation;
  record.texel_revision     = texel.revision();
  record.input_revisions    = revisions;

  returned = evaluated.begin();
  for (; returned != evaluated.end(); ++returned) {
    CachedOutput cached;
    cached.outcome = returned->second;
    if (!next_effective_revision(&cached.effective_revision)) {
      DemandResult result;
      result.outcome = ValueOutcome::error("spool effective revisions exhausted");
      result.effective_revision = 0;
      return result;
    }
    record.outputs[returned->first] = cached;
  }

  compute_cache[texel.id()]                = record;
  CachedOutputMap::const_iterator demanded = record.outputs.find(output);

  DemandResult result;
  result.outcome            = demanded->second.outcome;
  result.effective_revision = demanded->second.effective_revision;
  return result;
}

Spool::DemandResult Spool::cache_error(const Texel &texel, const String &output,
                                       U64 generation, const RevisionList &revisions,
                                       const String &message) {
  ComputeRecord record;
  record.checked_generation = generation;
  record.texel_revision     = texel.revision();
  record.input_revisions    = revisions;

  for (Size i = 0; i < texel.output_size(); ++i) {
    OutputPort declared;
    if (!texel.output_at(i, &declared)) {
      break;
    }

    CachedOutput cached;
    cached.outcome = ValueOutcome::error(message.c_str());
    if (!next_effective_revision(&cached.effective_revision)) {
      DemandResult result;
      result.outcome = ValueOutcome::error("spool effective revisions exhausted");
      result.effective_revision = 0;
      return result;
    }
    record.outputs[declared.name()] = cached;
  }

  compute_cache[texel.id()]                = record;
  CachedOutputMap::const_iterator demanded = record.outputs.find(output);

  DemandResult result;
  if (demanded == record.outputs.end()) {
    result.outcome            = ValueOutcome::error(message.c_str());
    result.effective_revision = 0;
    return result;
  }
  result.outcome            = demanded->second.outcome;
  result.effective_revision = demanded->second.effective_revision;
  return result;
}

bool Spool::next_effective_revision(U64 *revision) {
  if (revision == 0 || next_revision == std::numeric_limits<U64>::max()) {
    return false;
  }
  *revision = next_revision;
  ++next_revision;
  return true;
}

} // namespace lucia
