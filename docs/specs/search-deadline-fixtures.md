# Phase-observed deadline fixtures

This strengthens the actual controlled checks of
[SearchRun's absolute deadline](search-run-deadline.md). It changes test
orchestration, not the public API, deadline arithmetic, result disposition or
performance budgets. The old path case could expire in search before path
retrieval, and the old startup case could expire before full setup identity.
Those valid timeout results did not exercise the phase asserted by the fixture.
Retain both stopped consumer attempts; a diagnostic replay is not qualification.

Commit this contract and `test/support/deadline-fixture.expected.json` before
changing the fixture. All four hands use one caller-VM absolute deadline 3000 ms
after invocation and one independent operation cap of 10000 ms. These
are functional fixture windows, not latency ceilings or advertised performance
budgets. No deadline resets after phase observation.

The fake executable records each phase before work. Its selected held phase
replaces that same native PID with a long-lived `sleep 20` process. No helper
child is left behind. Search/path/probe completion output cannot be emitted by
the held phase. Startup and preload cases spend 1.2 seconds before the initial
prompt, then hold preload. The path case preserves a preceding 0.1-second
search delay. The complete zero-delay fixture remains a separate positive
control, including actual path and frontier output.

Run SearchRun in a monitored, caller-owned task. Observe the required phase
while the original absolute deadline is still future; retain that timestamp
before any phase-readiness assertion. If setup never reaches the selected
phase before expiry, fail the fixture rather than accepting another timeout
phase, retrying it or omitting a required check. The task receives explicit
options and the same original deadline. It must finish with its native worker
and process retired. Failure cleanup ends only the owned task and fixture.

Retain original hand/options/deadline before invocation, phase observations
before their guards, and full result/phase bytes/native PID before receipt
assertions. The path, frontier and preload cases require a full timeout receipt
with the original declared deadline and every finding, trace, state count,
probe and raw-output digest cleared. Path completion and post-preload search
remain absent. Accepted cancellation before invocation must retain cancelled
disposition even after preload holds through expiry; findings and trace remain
empty and the cancellation instance is consumed. Require native retirement in
every case. Real unbounded Maude timeout, finite completion, expired setup,
malformed deadlines, ordinary cancellation and owner-loss checks remain.

Keep all three budget seeds, 900 independent explicit-clock observations,
the two actual compiled budget faults with executed wrong reductions, all 45
directed backend runs, and the existing thirty-call null-threshold smoke.
Retain full source/compiled/native identities and complete actual outputs.
Run the complete owning `mix check --no-retry` with its required native tools.
No required failure becomes skipped-success. Conjunct may select the resulting
clean producer revision only after every required owning check passes; its
previous exact-cohort records remain historical and identifiable.
