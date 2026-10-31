#!/usr/bin/env bash
# Formats the code in place with swift-format, using the rules in .swift-format. Pass --check to lint instead,
# failing on any formatting difference or rule violation (this is what CI runs).
set -euo pipefail
cd "$(dirname "$0")/.."

paths=(Sources Tests Package.swift)
if [[ "${1:-}" == "--check" ]]; then
  exec swift format lint --strict --recursive --parallel "${paths[@]}"
fi
exec swift format format --in-place --recursive --parallel "${paths[@]}"
