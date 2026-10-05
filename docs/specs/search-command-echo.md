# Search command echo identity

SearchRun parser `ex_maude.search-run.v3` accepts Maude's layout changes in the
echo of the exact submitted normalized search command. The query digest still
hashes the original normalized command bytes. Layout tolerance does not equate
different terms, bounds, modules, patterns, conditions, string contents or
token boundaries. A refused echo remains `:parser_error` with
`:missing_command_echo`; it cannot become completed no-finding evidence.

The selected matcher compares every lexical token from `search` through the
standalone terminating period. Printable ASCII word tokens are delimited by
ASCII layout (space, tab, CR, LF, form feed, vertical tab). Parentheses,
brackets, braces and commas are separate tokens, unless backquoted. A
backquoted character remains part of its word token; the original spelling
must match. Double-quoted strings are one token, retaining every byte and C
escape spelling. Layout inside strings is significant. Invalid UTF-8, NUL,
unterminated strings/escapes, nonprinting word bytes and inputs over 16 MiB
refuse. String contents may contain UTF-8. An empty or unterminated command
refuses. After the echoed terminating period, only horizontal layout followed
by a line ending or end of input is allowed before completion output.

This is a bounded layout matcher, not a full Maude lexer or semantic term
equivalence engine. Comments, synonymous commands, equational simplification,
mixfix changes and pretty-printing that changes backquoted token spelling are
not normalized. Those forms can remain explicit parser refusals. It starts no
worker, creates no atoms and does not authenticate a native executable.

The [Maude 3.5.1 lexical grammar](https://maude.cs.illinois.edu/manual/maude-manualap2.html)
and [identifier conventions](https://maude.cs.illinois.edu/manual/maude-manualch3.html)
define token delimiters, backquoted identifiers and string escapes. Preserving
these boundaries avoids the false equivalences of removing all whitespace.

Hand expectations precede implementation: punctuation/layout variants,
multiline echo, exact and changed quoted whitespace/escapes, preserved and
changed backquoted tokens, merged words, wrong module/bounds/initial/pattern,
unknown prefixes, missing period and malformed byte/quote cases. A generated
property independently renders token lists with layout variations and a changed
numeric token; 300 examples per seed at 20261005, 27182818 and 31415926 must
accept the unchanged tokens and refuse the changed command. Compiled exact-byte
comparison and ignored-token faults must fail it with retained reduction.
Actual Maude searches with compact and spaced constructor arguments must have
the same findings and complete paths but distinct original query digests.

Before timing, verify hand refusal cases and a real compact/spaced search.
The declared matcher smoke uses one untimed preflight and 30 timed matches
(five groups of six) over retained actual echo bytes. Capture raw monotonic
microsecond intervals around matching only; validate results outside timing.
Retain source, executable, input, command identities and Elixir/OTP environment.
No performance threshold or other-target qualification is claimed.
