#!/bin/sh
# Fake Maude that never prints a prompt: accepts any arguments, swallows
# stdin, and stays alive. Used to test that Backend.Port's init fails fast
# instead of handing a never-ready worker to the pool.

while IFS= read -r _line; do
  :
done

sleep 600
