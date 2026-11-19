import XCTest
import Foundation

/// Guards Homebrew deprecated `url … verified:` (brew#23280).
/// The release workflow copies this template into `maimorto/homebrew-maccleaner`,
/// so a stale `verified:` here resurfaces as a `brew update` warning.
final class HomebrewCaskTests: XCTestCase {

    private var caskSource: String {
        get throws {
            let url = URL(filePath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appending(path: "Casks/maccleaner.rb")
            return try String(contentsOf: url, encoding: .utf8)
        }
    }

    func testCaskHasNoDeprecatedVerifiedParameter() throws {
        let src = try caskSource
        // Match the Homebrew url kwarg form (`verified: "…"`). Single-quoted
        // values are unused in this cask; official homebrew/cask omits it.
        let deprecated = src.range(
            of: #"\bverified:\s*""#,
            options: .regularExpression
        )
        XCTAssertNil(
            deprecated,
            "Casks/maccleaner.rb must not use the deprecated url verified: parameter"
        )
    }

    func testCaskUrlPointsAtGitHubReleaseDMG() throws {
        let src = try caskSource
        XCTAssertTrue(
            src.contains("url \"https://github.com/maimorto/mac-mop/releases/download/v#{version}/MacCleaner-#{version}.dmg\""),
            "Casks/maccleaner.rb must download the GitHub release DMG"
        )
    }

    func testCaskDeclaresRequiredStanzas() throws {
        let src = try caskSource
        for needle in ["cask \"maccleaner\"", "version ", "sha256 ", "homepage ", "app \"Mac Mop.app\""] {
            XCTAssertTrue(src.contains(needle), "Casks/maccleaner.rb missing \(needle)")
        }
    }
}
