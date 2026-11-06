---
name: security-review
description: "Assess requested security audits and changed structured-rule encoding, Maude execution, native protocols, parser limits, installation or release provenance. Trace input authority, process ownership and artifact identity; exclude unrelated mathematical-model review."
---

# Security review

Read [the repository instructions](../../../AGENTS.md), CONTRIBUTING and the
implemented entry point's contract. Distinguish implemented guarantees from
target requirements in verification specifications.

Establish input authority before tracing it. General term, raw-command and
module/file-loading APIs accept Maude code; executable and pool selection belong
to the host. Do not classify intentional code or executable authority as
injection without an additional privilege crossing. For structured
[AI](../../../lib/ex_maude/ai.ex) and [IoT](../../../lib/ex_maude/iot.ex) inputs,
follow the public facade through its validator, encoder, command and result
parser. Check alternate representations, string escaping, nesting and enum
validation at the actual consumer. Modeled tenants, capabilities, approvals and
jurisdictions do not implement host authorization or real tool/device actions.

Trace command construction through the selected backend, executable/argv,
transport framing, output parsing and worker reuse. Review
[Port](../../../lib/ex_maude/backend/port.ex),
[C-node](../../../lib/ex_maude/backend/cnode.ex) and
[NIF](../../../lib/ex_maude/backend/nif.ex) separately:
the [C bridge](../../../c_src/maude_bridge.c) is external, while
[Rust NIF code](../../../native/ex_maude_nif/src/lib.rs) runs inside the BEAM.
Inspect native decoder contracts, byte/allocation bounds, serialization,
request/response identity and cookie handling. Establish the authority of an
Erlang distribution peer rather than assuming an unauthenticated network input.
A backend response ceiling does not bound direct calls to public parsers.

Review [SearchRun](../../../lib/ex_maude/verification/search_run.ex) and
[IoT receipts](../../../lib/ex_maude/iot/receipt_run.ex) against their separate
profiles. Trace exact query/echo, model/checker/import identity, completion
classification and witness bounds. Apply the owning API's per-command timeout
or enclosing-deadline contract; SearchRun's explicit `:deadline_ms` is optional.
A timeout, malformed result, cancellation or truncated witness must not become
completed no-finding evidence. Unsigned attribution and bounded completion are
not executable authentication, positive safety proofs or OS containment.

Follow pool-specific [preloads](../../../lib/ex_maude/preloads.ex), private
snapshots and [subprocess ownership](../../../lib/ex_maude/subprocess.ex)
through startup, caller loss, cancellation, replacement and retirement. Do not
transfer one backend's ownership guarantee to another or infer descendant
cleanup, memory limits or hard return latency from direct-child termination.
Check telemetry and error payloads for command, rule, credential or private-state
disclosure, including opt-in behavior.

Inspect [binary resolution](../../../lib/ex_maude/binary.ex),
[installation](../../../lib/mix/tasks/maude.install.ex) and download handling for
effective executable selection, origins, credential recipients, expected digest,
archive/path bounds and destination authority. A digest from the release API
shares that upstream trust; it is not an independent signature.
For distribution changes, trace the [native release](../../../.github/workflows/release.yml)
and [Hex publisher](../../../.github/workflows/publish.yml) through repository,
run, tag, commit, version, checksums, package bytes and credential scope.
Review tracked source, examples and configuration for embedded access-granting
secrets without using them. An audit does not authorize installing interpreters,
fetching toolchains, publication or credential use.

Use existing validation commands from CONTRIBUTING and the selected public
path's regressions. Distinguish source inspection, a fake Maude process,
executed native tests and actual solver evidence. A missing solver or isolated
native harness leaves that proof unverified while source tracing continues.

## Scope, evidence and execution

For the requested review, record the revision and relevant working-tree changes,
checked entry/control/effect paths and deferred or excluded areas. A focused
review does not require a whole-repository audit.

Establish each claim against the strongest current control and owning contract.
Confirmed findings need a complete reachable boundary trace and evidence for
the stated consequence. Keep decisive unobserved facts as `needs_validation`,
with the exact missing check and no severity; reject disproved claims.
Distinguish source inspection, inspected tests, executed local tests and live
evidence. Group duplicate root causes and recheck previous findings against
current source and conditions.

Use the existing validation owner for authorized dummy-data regressions.
Executing untrusted code or hostile native/availability checks requires verified
OS isolation, no external networking, a sanitized environment and resource/time
limits. If unavailable, leave that execution unverified and continue source
review. A review grants no live/provider operations or agent-permission changes.
Independent verification is conditional on authorized, available delegation;
otherwise state the single-reviewer limit. Return findings in chat unless the
requested deliverable and repository contract permit a report.

Audit-method background: [Cloudflare's source-first workflow](https://github.com/cloudflare/security-audit-skill/tree/c1c8a8c1471069fb0e188eeaff69b8e8db6564a8/skills/security-audit).
