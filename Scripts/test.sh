#!/bin/zsh
# Runs `swift test`. With only the Command Line Tools installed (no Xcode), SwiftPM
# doesn't find Swift Testing, so add its framework and library search paths.
set -euo pipefail
cd "${0:a:h}/.."

flags=()
if [[ "$(xcode-select -p)" == /Library/Developer/CommandLineTools ]]; then
  dev=/Library/Developer/CommandLineTools/Library/Developer
  flags=(
    -Xswiftc -F -Xswiftc "$dev/Frameworks"
    -Xlinker -F -Xlinker "$dev/Frameworks"
    -Xlinker -rpath -Xlinker "$dev/Frameworks"
    -Xlinker -rpath -Xlinker "$dev/usr/lib"
  )
fi
exec swift test "${flags[@]}" "$@"
