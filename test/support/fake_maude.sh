#!/bin/sh
# Fake Maude for backend lifecycle tests: speaks just enough of the prompt
# protocol to drive ExMaude.Backend.Port without a real interpreter.
#
#   * prints the `Maude> ` prompt immediately and after every command
#   * `hang ...` lines produce no response (simulates a wedged interpreter
#     stuck in an unbounded rewrite)
#   * `quit` exits cleanly
#   * anything else is echoed back as a String result so tests can correlate
#     each response with the exact command that produced it

printf 'Maude> '

while IFS= read -r line; do
  case "$line" in
    quit*)
      exit 0
      ;;
    hang*)
      sleep 600
      ;;
    *)
      printf 'result String: "echo:%s"\nMaude> ' "$line"
      ;;
  esac
done
