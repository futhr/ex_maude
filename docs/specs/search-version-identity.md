# Complete executable version identity

SearchRun cannot produce a completed receipt when executable identification
returns empty, malformed or oversized version output. Successful `--version`
exit status is insufficient. Identification precedes model snapshot creation
and worker startup; refusal returns a typed load error and cannot become an
empty completed search. Existing absolute deadlines and caller-loss ownership
apply to this native identification operation.

The passive public `Verification.Version.decode/1` decodes an opaque reported
version label. Input is binary UTF-8 with no NUL, at most 65536 bytes. Strip only
leading/trailing ASCII space, tab, CR and LF; retain every interior byte and
other Unicode character. The resulting label must be nonempty. Nonbinary input
is a validation refusal; oversized input is response-too-large; invalid UTF-8,
NUL and missing labels are parse refusals. No clock, process, configuration,
telemetry or application startup is involved.

This does not enforce semantic version syntax, a particular Maude major,
executable authenticity, transitive executable dependency identity or a
positive verification profile. Executable digests still identify the selected
file bytes; the host owns executable selection. The label records measured
output, not a caller assertion or a substitute for the executable digest.

Hand expectations include empty/layout-only output, signed/Unicode opaque
labels, exact internal layout, NUL, invalid UTF-8, malformed arguments and both
sides of the byte cap. A property independently renders 300 version/blank
labels per seed at 20261005, 27182818 and 31415926. It also inserts NUL and
invalid UTF-8 without changing the physical inputs. Retain original bytes,
expectations and complete actual results before assertions. Compiled
accepted-blank and ignored-UTF8 faults must fail with recorded reductions.
Public controlled CLI cases require refusal before worker startup; a separate
actual Maude run must retain its decoded native version label.

Before timing, require the hand/property refusal preflight and actual finite
Maude completion. The declared decoder smoke has one untimed preflight and 30
timed calls (five groups of six) over the actual native version bytes. Timing
covers the decoder only; validation and evidence writes are outside timing.
Retain full inputs/results, source/executable/environment identities and raw
monotonic microsecond intervals. No latency or memory threshold is claimed.
