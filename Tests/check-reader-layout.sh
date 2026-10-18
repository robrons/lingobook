#!/bin/bash
set -euo pipefail
# Usage: Tests/check-reader-layout.sh /path/to/Xcode/DerivedData/LingoBook-... [book.epub]
# Build the Debug macOS scheme first. Optional book input is read-only.
root="$(cd "$(dirname "$0")/.." && pwd)"
derived="${1:?Pass the existing Xcode DerivedData directory}"
products="$derived/Build/Products/Debug"
wrappers="$derived/SourcePackages/checkouts/FluidAudio/Sources"
check_dir="$(mktemp -d /tmp/lingobook-layout-check.XXXXXX)"
trap 'rm -rf "$check_dir"' EXIT
swiftc -parse-as-library -I "$products" \
    -I "$wrappers/MachTaskSelfWrapper/include" -I "$wrappers/FastClusterWrapper/include" \
    "$root/Tests/ReaderLayoutChecks.swift" \
    "$products/LingoBook.app/Contents/MacOS/LingoBook.debug.dylib" -o "$check_dir/checks"
DYLD_LIBRARY_PATH="$products/LingoBook.app/Contents/MacOS" "$check_dir/checks" "${@:2}"
