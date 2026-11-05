---
name: security-review
description: "Assess requested security reviews or audits and changed Maude command construction, subprocess/NIF execution, parser limits or installer downloads. Trace caller input, process authority, deadlines and artifact integrity; exclude unrelated mathematical-model review."
---

# Security review

Read [the repository instructions](../../../AGENTS.md), CONTRIBUTING and the
owning verification or installer contract. Separate trusted operator-authored
Maude programs from lower-trust expressions, files, executable selectors and
download metadata. A mathematical result does not establish host containment.

Trace input through validation/encoding, executable and argv selection,
[subprocess ownership](../../../lib/ex_maude/subprocess.ex), output parsing and
[verification receipts](../../../lib/ex_maude/verification/search_run.ex).
Check exact command/echo identity, framing, byte/depth/work bounds, one enclosing
deadline, owner cancellation and process retirement. Do not infer operating
system isolation from a BEAM timeout or a result tagged verified.

Review [the native boundary](../../../native/ex_maude_nif/src/lib.rs) separately
from the external process. Check which failures can affect the BEAM and which
claims require an isolated native fixture. Inspect
[installation](../../../lib/mix/tasks/maude.install.ex) and download handling for
trusted origins, artifact identity, archive/path safety and executable authority.
An audit does not authorize installation or fetching toolchains.

Use the existing subprocess, parser, installer and verification regressions for
the selected public path. Distinguish a fake Maude process, native library proof
and actual solver execution. A missing solver or native harness leaves that
proof unverified while source tracing continues.

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
