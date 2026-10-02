#!/usr/bin/env bash
# Runs the test suite. With only the Command Line Tools installed (no Xcode), the Swift Testing
# framework lives outside the default search path, so point the compiler and linker at it.
set -euo pipefail

frameworks="$(xcode-select -p)/Library/Developer/Frameworks"
if [[ -d "$frameworks/Testing.framework" ]]; then
  exec swift test -Xswiftc -F"$frameworks" -Xlinker -F"$frameworks" -Xlinker -rpath -Xlinker "$frameworks" "$@"
fi
exec swift test "$@"
