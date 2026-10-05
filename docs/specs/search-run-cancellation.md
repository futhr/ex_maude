# SearchRun cancellation

This additive contract extends `ExMaude.Verification.SearchRun.run/3`. It does
not change legacy search or IoT receipt entry points.

**ESC-01.** A host explicitly starts and supervises a
`ExMaude.Verification.Cancellation` instance, then passes its PID as
`:cancellation` to one `SearchRun.run/3`. Loading ExMaude starts no instance.
Each instance is single-use, has a temporary restart policy and owns at most
one isolated worker. Hosts assign distinct child IDs when supervising several
instances. A second run cannot claim an active or closed instance.

**ESC-02.** `Cancellation.request/1` returns `:ok` when the request is recorded.
This acknowledgment is not a search receipt or a proof that preparation has
finished. A request preceding worker registration remains recorded. Startup
and executable identification retain their existing explicit timeout limits;
cancellation does not interrupt filesystem preparation or executable-version
identification. A subsequently registered worker is retired before any search
command is submitted.

**ESC-03.** Once a worker is registered, requesting cancellation synchronously
stops that worker through the Port backend. The worker cannot be reused. The
search result is settled only after worker retirement and cancellation-instance
closure. A cancelled result has `termination: :cancelled`, an error of type
`:cancelled`, no solutions, state count, trace or depth probe, and no claimed
complete raw-output digest. Its exact model, query, executable, session and
effective-limit identities remain present. Empty findings do not establish a
completed search or absence of counterexamples.

**ESC-04.** Closure is the completion/cancellation race boundary. A request
processed before closure wins; a request after closure returns
`{:error, %ExMaude.Error{type: :validation}}` and cannot relabel an earlier
receipt. Repeated requests before closure are idempotent. Closing or cancelling
one instance cannot affect another instance's worker or receipt.

**ESC-05.** Only the claiming run can register or close its worker. Caller death
retires the registered worker and closes the instance. Instance shutdown retires
its worker; abrupt instance loss is monitored by the run. Lost cancellation
ownership yields `:worker_loss`, not a completed receipt. Existing Port native
process cleanup remains authoritative. No mutable application configuration,
pool singleton or consumer-side private worker control is introduced.

**ESC-T1–T6.** Required checks cover a recorded early request, an actual in-flight
Maude search, late and duplicate requests, two independent instances, owner and
supervisor loss, and generated request/closure schedules. Telemetry exposes only
bounded classifications and counts. Preserve the failing original schedule and
its independent expected receipt when a regression is found.

The lifecycle uses [GenServer stop semantics](https://hexdocs.pm/elixir/GenServer.html#stop/3)
and [OTP process monitors](https://www.erlang.org/docs/28/system/ref_man_processes.html).
Worker termination and external OS-process reaping are distinct observations;
tests must check both rather than inferring OS cleanup from a result label.
The inspected online GenServer documentation is for Elixir 1.20.4; the producer
remains on its own Elixir 1.19.4 / OTP 28.5 pins. Generated checks run 300 real
Maude schedules per seed with seeds 20261005, 27182818 and 31415926. A shrinker
retains the original and minimal failing request schedule in the test log.

`mix run tools/check_search_cancellation.exs` is a mandatory part of
`mix check --no-retry`. It archives the actual Git-listed source bytes and pins
each file before execution, checks all 900 original schedules and receipts,
then compiles two separate source mutations outside the checkout. The
misclassified cancellation and accepted late request must each fail the
generated property with a retained reduced schedule. Every run uses a fresh
random evidence directory; evidence from previous BEAM instances cannot satisfy
its counters. The source must remain unchanged throughout the campaign.

The installed-archive check uses `tools/search_cancellation_consumer.exs` in a
fresh host project depending only on the unpacked Hex archive. Stage locked
dependency sources and compile the consumer first with `EX_MAUDE_BUILD=0` and
`EX_MAUDE_BUILD_CNODE=0`. Then run
`elixir -pa '_build/dev/lib/*/ebin' search_cancellation_consumer.exs`,
with network access disabled and an explicit
`MAUDE_PATH`. Mix compilation uses a local PubSub TCP socket; this is why the
network-denied execution uses the already compiled application through Elixir.
The check proves passive loading, two independent instances and supervisor
closure. Its host-supplied GPL Maude executable is a declared external asset,
not bundled into the Hex archive. This Port check does not qualify NIF
cancellation, state-count limits or the broader positive-proof profile.

## Declared smoke workload

Before timing, execute all correctness checks. Measure the real public
single-use request plus bounded SearchRun preparation/retirement path, including
startup, with the installed Maude executable: one untimed preflight, five
retained samples, monotonic microseconds, complete receipt validation outside
each interval. Retain executable/model/query digests, compiler/OTP versions,
raw intervals and outcome. This is a local correctness smoke workload with no
latency threshold, peak-throughput or whole-platform qualification claim.
Stage the complete source before the qualified smoke run; its report retains
the staged tree and patch identity and refuses unstaged changes before timing.
