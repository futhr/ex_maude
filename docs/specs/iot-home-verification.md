# IoT/home verification contract

## Status

Target clarification for the existing `ExMaude.IoT` API. The current implementation already provides conflict detection and bounded safety verification; this document does not claim a new verifier.

## Consumer-neutral requirement

ExMaude remains independent of WoTEx and any home product. A consumer supplies deterministic IoT rules and a bad-state pattern.

The existing semantic distinction is normative for safety-oriented consumers:

- `{:error, {:counterexample, solutions}}` means a reachable bad world was found within the executed search;
- `{:ok, :unverified}` means no counterexample was established within the bounded execution, or the verification could not establish the requested property;
- validation/backend errors remain typed errors and MUST NOT be converted into success.

A bounded absence of counterexamples is not automatically a proof of safety.

## Home/physical-IoT composition

A consumer may model:
- Things and Properties;
- Actions as semantic state effects;
- rule triggers and priorities;
- environment effects;
- safety invariants expressed as bad-state patterns.

It SHOULD NOT model transport packets, HTTP calls, Zigbee frames or vendor wire details.

## Recommended additive API work

To support reproducible physical-IoT evidence without coupling to a consumer, a future additive result/receipt API SHOULD expose:
- verification operation;
- rule/model digest;
- initial-state digest when supplied;
- bad-state/pattern digest;
- search bound/depth;
- Maude/backend version identity;
- outcome: counterexample or unverified/established according to the exact operation;
- counterexample witness/solutions when present;
- elapsed/resource metadata without raw private command text.

Existing return shapes remain compatible until an explicit versioned API is accepted.

## Safety rule

Consumers MUST fail closed when their own policy requires verification and ExMaude returns unverified, timeout, unavailable or typed backend failure.

## Evidence

Add tests proving:
- counterexample is never collapsed into ordinary error text;
- timeout/unavailable cannot become verified;
- bounded no-counterexample remains unverified;
- receipts/digests, if implemented, are deterministic for identical explicit inputs;
- telemetry excludes raw home/private state by default.
