#!/bin/bash
# Targeted regression checks on macOS with Command Line Tools (no XCTest required).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="$(mktemp -d "${TMPDIR:-/tmp}/lazyspace-regression.XXXXXX")"
trap 'rm -rf "$BUILD"' EXIT
cd "$ROOT"
swiftc -emit-library -emit-module -module-name Copy Sources/Copy/*.swift -o "$BUILD/libCopy.dylib" -emit-module-path "$BUILD/Copy.swiftmodule"
swiftc -emit-library -emit-module -module-name LayoutCore Sources/LayoutCore/*.swift -o "$BUILD/libLayoutCore.dylib" -emit-module-path "$BUILD/LayoutCore.swiftmodule"
swiftc -emit-library -emit-module -module-name Operations -I "$BUILD" -L "$BUILD" -lLayoutCore -lCopy Sources/Operations/*.swift -o "$BUILD/libOperations.dylib" -emit-module-path "$BUILD/Operations.swiftmodule"
swiftc -emit-library -emit-module -module-name Settings -I "$BUILD" -L "$BUILD" -lLayoutCore -lCopy Sources/Settings/*.swift -o "$BUILD/libSettings.dylib" -emit-module-path "$BUILD/Settings.swiftmodule"
swiftc -emit-library -emit-module -enable-testing -module-name MacSupport -I "$BUILD" -L "$BUILD" -lLayoutCore -lOperations -lCopy Sources/MacSupport/*.swift -o "$BUILD/libMacSupport.dylib" -emit-module-path "$BUILD/MacSupport.swiftmodule"
APP_SOURCES=()
for source in Sources/LazySpaceApp/*.swift; do
    # AppMain.swift starts the app; SparkleUpdates.swift is the only Sparkle file and MacNotifier.swift the only UserNotifications
    # file, so the checks use no updater and no notification center.
    [[ "$source" == "Sources/LazySpaceApp/AppMain.swift" || "$source" == "Sources/LazySpaceApp/SparkleUpdates.swift" || "$source" == "Sources/LazySpaceApp/MacNotifier.swift" ]] || APP_SOURCES+=("$source")
done
swiftc -emit-library -emit-module -enable-testing -module-name LazySpaceApp -I "$BUILD" -L "$BUILD" -lLayoutCore -lOperations -lSettings -lMacSupport -lCopy "${APP_SOURCES[@]}" -o "$BUILD/libLazySpaceApp.dylib" -emit-module-path "$BUILD/LazySpaceApp.swiftmodule"
swiftc -I "$BUILD" -L "$BUILD" -lLayoutCore -lOperations -lSettings -lMacSupport -lLazySpaceApp -lCopy -Xlinker -rpath -Xlinker "$BUILD" Tests/OperationsTests/FakeSystem.swift Tests/LazySpaceTests/CoordinatorSystem.swift Tests/LazySpaceTests/AutomaticIntegrationChecks.swift Tests/MacSupportTests/FrameWriterChecks.swift Tests/AutoRegression/main.swift -o "$BUILD/checks"
LAZYSPACE_LANGUAGE=en "$BUILD/checks"
