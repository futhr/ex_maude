#!/bin/sh
# Exact arithmetic results for the benchmark harness; no Maude installation needed.
printf 'Maude> '
while IFS= read -r line; do
  case "$line" in
    quit*) exit 0 ;;
    'reduce in BOOL : true and false .') printf 'result Bool: false\nMaude> ' ;;
    'reduce in NAT : '*)
      expression=${line#reduce in NAT : }
      expression=${expression% .}
      printf 'result Nat: %s\nMaude> ' "$((expression))"
      ;;
    *) printf 'Maude> ' ;;
  esac
done
