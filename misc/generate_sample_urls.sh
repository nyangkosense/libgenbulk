#!/bin/bash

N="$1"
INPUT="$2"
OUTPUT="$3"

if [[ -z "$N" || -z "$INPUT" || -z "$OUTPUT" ]]; then
  echo "Usage: $0 <number_of_lines> <input_file> <output_file>"
  exit 1
fi

shuf -n "$N" "$INPUT" > "$OUTPUT"

