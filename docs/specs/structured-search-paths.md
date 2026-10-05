# Structured search paths

`ExMaude.Verification.Path.decode/3` is an additive, passive decoder for the
Port backend's returned `show path` bytes. It never contacts a worker or selects
a model. SearchRun's existing raw path and completion API remain unchanged.

**ESP-01.** Inputs are exact UTF-8 bytes, a requested nonnegative state number
through 4294967295, and keyword options. Default `max_bytes` is 16777216;
default `max_nodes` is 10000. Positive explicit limits can narrow these caps.
Malformed options, duplicate/unknown keys and invalid targets are validation
errors. Byte/node cap exhaustion is `:response_too_large`; malformed syntax,
unknown text, incomplete paths and target mismatch are `:parse_error`.

**ESP-02.** The accepted representation alternates an initial state, a complete
printed rewrite rule, and the next state. State lines have `state N, SORT:
VALUE`; SORT and VALUE are retained as text, without atom creation or term
interpretation. State values occupy one line in this selected unwrapped Port
profile. Rule blocks begin `===[ ` and end ` ]===>`; their complete printed
`rl` or `crl` body, including any internal lines, remains present. A leading
rule label is exposed as text when present; unlabeled rules have a nil label.
Labels declared only as attributes remain part of the opaque rule body.

**ESP-03.** A successful result records parser version `ex_maude.path.v1`,
SHA-256 of the exact input bytes, the requested state number, every ordered
node (`state_num`, `sort`, `value`) and every edge (`from_state`, `to_state`,
`rule`, `label`). The first node is state 0, the last is the requested state,
all numbers are unique and bounded, and exactly one edge joins each adjacent
pair. State IDs need not be consecutive. A path to state 0 has one node and no
edges. No prefix, extra unknown line, omitted rule or dangling edge is accepted.
LF and CRLF separators and one terminal separator are allowed; input identity
always hashes the original bytes. Bare carriage returns and NUL are refused.

**ESP-04.** Parsing is structural evidence. It does not verify a rule against
model bytes, prove a transition, authenticate execution, establish exhaustive
search, interpret arbitrary Maude terms or replay a physical/compiler model.
Consumers bind this result to the actual SearchRun receipt's raw digest and
target, retain the model/session identity, and independently check every
transition before representing the path as a replayed witness. Unsupported
multiline state formatting refuses explicitly; it cannot become an empty path.

The [Maude 3.5.1 system-module manual](https://maude.cs.illinois.edu/manual/maude-manualch5.html)
defines the path command and shows graph state IDs that skip numbers. The
decoder preserves those IDs and printed rules; a generic consecutive-number
assumption would reject a valid search graph path.

## Required evidence and declared smoke

Hand-prepared expectations cover a two-edge path with IDs 0, 2 and 4, a
zero-edge path, unknown/missing/duplicate/dangling elements, wrong target,
invalid bytes, resource caps, label omission and line separators. A generated
property renders independently prepared node/edge lists with varying gaps,
values and labels; 300 cases per seed at 20261005, 27182818 and 31415926 must
round-trip all fields and digest. Compiled target-mismatch and dropped-edge
mutations must fail those expectations. Actual Maude tests decode complete
multi-step and zero-step SearchRun paths from the same retired session.

Before timing, decode and verify a real two-edge Maude path and the refusal
fixtures. The smoke workload has one untimed decoder preflight and 30 timed
public decodes (five groups of six), on identical retained input bytes.
Measure monotonic microseconds around decode only; consume/check every returned
node, edge and digest outside the interval. Retain raw intervals, complete
results, executable/source identities and Elixir/OTP environment. No latency,
throughput or memory threshold or other-target qualification is claimed.
