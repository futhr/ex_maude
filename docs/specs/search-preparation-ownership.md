# Ownership before search readiness

An isolated SearchRun owns its private model snapshot and native executable
identification process from creation, including the interval before a ready
Port worker exists. Killing the caller bypasses its `after` blocks; cleanup
cannot depend on those blocks or a watcher installed only after readiness.
Ownership must be registered before the side effect being guarded. A monitor
must also handle an owner that died before registration completed.

Private snapshot creation runs in a passive, explicitly started owner monitor.
The monitor generates its own unpredictable directory, writes the exact bytes
with directory mode 0700 and model mode 0400, and retains ownership until
explicit closure or caller death. Closure removes the directory before
acknowledging and stops the monitor. Failed creation removes partial output.
Only the owning caller may close a lease through the internal API; another
caller receives a validation refusal without changing the snapshot.
Loss during creation removes output when that synchronous operation settles;
this is not filesystem preemption. Independent owners/leases cannot remove or
change each other's bytes. No caller-provided directory is adopted for cleanup.

The internal `ExMaude.Subprocess.run/4` keeps its output/status, timeout and
output-overflow result contract. Its native process is owned by an unlinked
collector monitoring the caller before opening the port. Caller loss interrupts
collection and retires the directly spawned native process. Normal return and
refusal also retire it before reply. The caller's exit flags are unchanged.
Its relative budget starts before collector creation, not after native startup.
The internal additive `run/5` accepts the enclosing absolute monotonic deadline
as its fifth argument (`:none` preserves `run/4`). The collector uses the earlier
of that deadline and the relative cap, checks expiry before native creation,
and retains that timestamp while collecting. Queuing or opening the port cannot
restart the enclosing SearchRun budget. Expired dispatch returns timeout without
creating the native child.
This does not qualify descendant process trees, external executable sandboxes,
VM/OS crash cleanup, hard real-time latency or another operating system target.

SearchRun keeps these producers' ownership boundaries: it does not expose a
private worker controller to Conjunct. Early cancellation still records a
request rather than interrupting identity/snapshot preparation; caller loss
is independent of cancellation. Complete/cancelled/expired result semantics
and exact model/query/executable identities remain unchanged.

Independent public cases record the native PID before forcing caller loss
during `--version` and the model-load command before forcing loss during
preloading. They require retirement and snapshot removal without receiving a
completed receipt. Generated snapshot schedules compare exact independent
bytes before and after another owner's closure/loss; generated subprocess
schedules force both killed and shutdown owners of stopped native children.
Each property runs 300 examples at seeds 20261005, 27182818 and 31415926, with
original inputs and complete observations retained before assertions.
Compiled omitted-snapshot-cleanup and ignored-owner-loss faults must fail
actual assertions and retain reduced schedules. Cleanup performed by the test
after a failure is recorded separately and cannot turn that failure into a pass.

Before measurement, require actual public phase-loss checks and the independent
property/refusal preflight. The declared smoke starts two private snapshots,
closes the first while reading unchanged second bytes, then closes the second:
one untimed preflight and five timed schedules. Retain exact bytes, source and
environment, start/end monotonic microseconds and full closure/readback results.
Validation and evidence writes are outside timing. No performance threshold
or peak-memory qualification is claimed.
