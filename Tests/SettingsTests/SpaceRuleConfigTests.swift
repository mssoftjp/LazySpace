import XCTest
import Settings

/// `action = "space"` rules: numeric destination, explicit follow, loading, and comment-preserving save.
final class SpaceRuleConfigTests: XCTestCase {
    func testSpaceRulesAreTypedAndSeparateFromTilingExclusion() throws {
        let c = try Config.load(toml: """
        exec-on-window-sent = ["/bin/sh", "-c", "echo sent"]
        [[rule]]
        app = "com.google.Chrome"
        title = "Meet"
        action = "space"
        space = 3
        follow = true
        [[rule]]
        app = "com.apple.TextEdit"
        action = "space"
        space = 2
        [[rule]]
        app = "com.example.digits"
        action = "space"
        space = 4
        """)
        XCTAssertEqual(c.rules[0], Config.Rule(app: "com.google.Chrome", action: .space, title: "Meet", space: 3, follow: true))
        XCTAssertEqual(c.rules[1].space, 2)
        XCTAssertEqual(c.rules[1].follow, false, "follow defaults to false")
        XCTAssertEqual(c.rules[2].space, 4)
        XCTAssertEqual(c.execOnWindowSent, ["/bin/sh", "-c", "echo sent"])
        // Separate from tiling exclusion: a window matching only a space rule is still arranged.
        XCTAssertNil(c.tilingExclusionReason(bundleID: "com.google.Chrome", title: "Meet"))
        XCTAssertNil(c.rule(for: "com.apple.TextEdit"))
        XCTAssertEqual(c.spaceRule(for: "com.google.Chrome", title: "Google Meet")?.index, 0)
        XCTAssertNil(c.spaceRule(for: "com.google.Chrome", title: "Inbox"), "the title condition applies")
        XCTAssertTrue(c.hasSpaceRule(forApp: "com.google.Chrome"))
        XCTAssertFalse(c.hasSpaceRule(forApp: "com.apple.Safari"))
        // Renders and loads back with the same types.
        XCTAssertEqual(try Config.load(toml: c.render()), c)
    }

    func testSpaceRuleProblems() {
        for (toml, fragment) in [
            ("[[rule]]\napp = \"a\"\naction = \"space\"\n", "needs space"),
            ("[[rule]]\napp = \"a\"\naction = \"space\"\nspace = 0\n", "1 to 99"),
            ("[[rule]]\napp = \"a\"\naction = \"space\"\nspace = \"  \"\n", "needs space"),
            ("[[rule]]\napp = \"a\"\naction = \"space\"\nspace = \"web\"\n", "needs space = <number>"),
            ("[[rule]]\napp = \"a\"\naction = \"space\"\nspace = 2\nfollow = \"yes\"\n", "follow must be"),
            ("[[rule]]\napp = \"a\"\naction = \"float\"\nspace = 2\n", "only for action"),
            ("[[rule]]\napp = \"a\"\naction = \"teleport\"\n", "ignore, float, or space"),
        ] {
            XCTAssertThrowsError(try Config.load(toml: toml), fragment) { error in
                let text = (error as? Config.LoadError)?.problems.joined(separator: " ") ?? "\(error)"
                XCTAssertTrue(text.contains(fragment), "\(fragment): \(text)")
            }
        }
    }

    /// The Settings save (comment-preserving) also rewrites space and follow.
    func testCommentPreservingSaveUpdatesSpaceFields() throws {
        let text = """
        # my rules
        [[rule]]
        app = "com.google.Chrome"   # browser
        action = "space"
        space = 3
        """
        let before = try Config.load(toml: text)
        var after = before
        after.rules[0].space = 2
        after.rules[0].follow = true
        let saved = try ConfigDocument.applying(after, to: text, replacing: before)
        XCTAssertTrue(saved.contains("# browser"))
        XCTAssertTrue(saved.contains("space = 2"), saved)
        XCTAssertTrue(saved.contains("follow = true"), saved)
        XCTAssertEqual(try Config.load(toml: saved).rules, after.rules)
    }

}
