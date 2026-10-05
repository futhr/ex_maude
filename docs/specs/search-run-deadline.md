# SearchRun absolute execution deadline

The additive `:deadline_ms` option is an integer in the caller VM's
`System.monotonic_time(:millisecond)` clock domain. Negative timestamps are
valid. It must not be reused across VMs or interpreted as UTC. Omission retains
the current per-operation timeout behavior. `:timeout` remains a positive
per-operation cap. A supplied absolute deadline never resets between phases.

Before executable identification, snapshot preparation, native startup, search,
path retrieval and frontier probing, remaining time is the deadline minus the
current monotonic clock. An expired budget refuses further native dispatch.
Each bounded native wait uses the smaller of remaining time and the existing
per-operation cap. Startup shares this absolute budget across its initial
prompt and all model preloads. The Port backend owns that startup boundary;
the consumer cannot implement a private worker controller.

`ExMaude.Backend.Port.start/1` starts an unlinked worker owned by the calling
process. Startup failure returns an error without changing the caller's exit
flags. Owner loss during startup or ready operation retires the worker and
native process. Existing `start_link/1` remains available for host supervision.
SearchRun uses the caller-owned form so a startup timeout is typed evidence.

The result is settled again after parsing and worker retirement, before stop
telemetry callbacks. A full receipt
observed after expiry has termination `:timeout`, a timeout error, no solutions,
state count, trace, depth probe or complete raw-output digest. Exact identified
model/query/executable/session identities and declared limits remain. A supplied
deadline is retained in limits; omitted deadlines preserve the previous limit
shape. Setup expiry before full identity is available returns a timeout error,
never an empty completed receipt. Validation errors remain validation errors.
Accepted cancellation preceding closure retains its cancellation disposition;
it cannot become completed evidence because of a deadline race.

Synchronous filesystem reads/writes and parsing are checked before and after
execution; this API does not preempt them. Native waits are bounded, and worker
retirement is required before return. Scheduler/filesystem/retirement latency
may delay delivery beyond the timestamp. This deadline controls admissible
results and native work; it is not a hard real-time return-latency guarantee,
an OS memory sandbox, a state-count limit or a positive proof profile.

The passive budget helper uses explicit integer clock observations. Independent
hand tables include signed clocks, exact expiry, one remaining millisecond,
the smaller per-operation cap, malformed inputs and omitted deadlines. A
property independently calculates remaining budgets over three ordered phase
observations; 300 examples per seed at 20261005, 27182818 and 31415926 retain
original and actual values. Compiled restarted-deadline and accepted-expiry
faults must fail with recorded reduction. Actual backend checks cover expired
setup, finite completion, in-flight unbounded Maude timeout, cumulative
startup/preload/search/path/probe delays, cancellation, isolation and retirement.

Before timing, run the hand/property refusal preflight and a real finite/expired
search. The declared smoke has one untimed helper preflight and 30 timed budget
calculations (five groups of six), with explicit retained clock inputs. Measure
monotonic microseconds around the helper only and check complete results outside
timing. Retain source/executable/input/environment identities and raw intervals.
No latency threshold, hard real-time or other-target qualification is claimed.
