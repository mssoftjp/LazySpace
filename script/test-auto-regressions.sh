#!/bin/bash
# Targeted regression checks without XCTest. Needs Xcode: xcstringstool (String Catalogs) is not in the Command Line Tools.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="$(mktemp -d "${TMPDIR:-/tmp}/lazyspace-regression.XXXXXX")"
trap 'rm -rf "$BUILD"' EXIT
cd "$ROOT"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

# Each module gets its own directory: the generated catalog symbols look for <lang>.lproj next to the module's library.
LINK=()
module() { # name, then -l flags and sources
    local name="$1"; shift
    local dir="$BUILD/$name" sources=() libs=()
    mkdir -p "$dir"
    for arg in "$@"; do
        if [[ "$arg" == -l* ]]; then libs+=("$arg"); else sources+=("$arg"); fi
    done
    local catalog="Sources/$name/Resources/Localizable.xcstrings"
    if [[ -f "$catalog" ]]; then
        mkdir -p "$dir/gen"
        xcrun xcstringstool generate-symbols "$catalog" -o "$dir/gen" -l swift >/dev/null
        xcrun xcstringstool compile "$catalog" -o "$dir" >/dev/null
        sources+=("$dir"/gen/*.swift)
    fi
    swiftc -emit-library -emit-module -enable-testing -module-name "$name" ${LINK[@]+"${LINK[@]}"} ${libs[@]+"${libs[@]}"} "${sources[@]}" \
        -o "$dir/lib$name.dylib" -emit-module-path "$dir/$name.swiftmodule"
    LINK+=(-I "$dir" -L "$dir" -Xlinker -rpath -Xlinker "$dir")
}

module Copy Sources/Copy/*.swift
module LayoutCore Sources/LayoutCore/*.swift
module Operations -lLayoutCore -lCopy Sources/Operations/*.swift
module Settings -lLayoutCore -lCopy Sources/Settings/*.swift
module MacSupport -lLayoutCore -lOperations -lCopy Sources/MacSupport/*.swift
APP_SOURCES=()
for source in Sources/LazySpaceApp/*.swift; do
    # AppMain.swift starts the app; SparkleUpdates.swift is the only Sparkle file and MacNotifier.swift the only UserNotifications
    # file, so the checks use no updater and no notification center.
    [[ "$source" == "Sources/LazySpaceApp/AppMain.swift" || "$source" == "Sources/LazySpaceApp/SparkleUpdates.swift" || "$source" == "Sources/LazySpaceApp/MacNotifier.swift" ]] || APP_SOURCES+=("$source")
done
module LazySpaceApp -lLayoutCore -lOperations -lSettings -lMacSupport -lCopy "${APP_SOURCES[@]}"
swiftc "${LINK[@]}" -lLayoutCore -lOperations -lSettings -lMacSupport -lLazySpaceApp -lCopy Tests/OperationsTests/FakeSystem.swift Tests/LazySpaceTests/CoordinatorSystem.swift Tests/LazySpaceTests/AutomaticIntegrationChecks.swift Tests/MacSupportTests/FrameWriterChecks.swift Tests/AutoRegression/main.swift -o "$BUILD/checks"
LAZYSPACE_LANGUAGE=en "$BUILD/checks"
