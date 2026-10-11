# Tests

Run the complete suite with `swift test`. The package targets separate pure layout
and settings logic, operation safety, macOS adapters, and app integration.

`bash script/test-auto-regressions.sh` runs the shared operation and frame-writer
checks without XCTest, using Command Line Tools. `AutomaticIntegrationChecks.swift`
and `FrameWriterChecks.swift` are intentionally shared with the XCTest wrappers;
do not copy their assertions into the standalone runner.

`CopyTests/WordingRulesTests.swift` checks product strings and the user documents against
the wording rules defined in that file and reports `file:line: rule: text`.

Tests must not show anything on screen or depend on what the user is doing. Build Settings
and window-list controllers through `TestWindows` (transparent, click-through, unanimated
windows), and give Coordinator fixtures their mouse and display state through
`CoordinatorSystem` (`anyMouseButtonHeld`, `displays`).
