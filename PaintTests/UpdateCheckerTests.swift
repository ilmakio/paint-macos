import XCTest
@testable import Paint

final class AppVersionTests: XCTestCase {

    func testParsesTagsWithAndWithoutPrefix() {
        XCTAssertEqual(AppVersion("v1.0.2")?.components, [1, 0, 2])
        XCTAssertEqual(AppVersion("1.0.2")?.components, [1, 0, 2])
        XCTAssertEqual(AppVersion(" 1.2.3 ")?.components, [1, 2, 3])
    }

    func testRejectsNonsense() {
        XCTAssertNil(AppVersion(""))
        XCTAssertNil(AppVersion("v"))
        XCTAssertNil(AppVersion("latest"))
        XCTAssertNil(AppVersion("1.x.0"))
    }

    /// The whole point of parsing rather than string-comparing: 10 beats 9.
    func testComparesNumericallyNotLexically() throws {
        let older = try XCTUnwrap(AppVersion("1.0.9"))
        let newer = try XCTUnwrap(AppVersion("1.0.10"))
        XCTAssertLessThan(older, newer)
        XCTAssertGreaterThan(newer, older)
    }

    func testMinorBeatsPatch() throws {
        let patch = try XCTUnwrap(AppVersion("1.0.99"))
        let minor = try XCTUnwrap(AppVersion("1.1.0"))
        XCTAssertLessThan(patch, minor)
    }

    func testMissingComponentsCountAsZero() throws {
        let short = try XCTUnwrap(AppVersion("1.0"))
        let long = try XCTUnwrap(AppVersion("1.0.0"))
        XCTAssertFalse(short < long)
        XCTAssertFalse(long < short)
        XCTAssertEqual(short, long)
    }

    func testPrereleaseSortsBeforeItsRelease() throws {
        let beta = try XCTUnwrap(AppVersion("1.1.0-beta.1"))
        let final = try XCTUnwrap(AppVersion("1.1.0"))
        XCTAssertLessThan(beta, final)
        XCTAssertEqual(beta.description, "1.1.0-beta.1")
    }

    func testShippedVersionIsNotSeenAsAnUpdate() throws {
        let current = try XCTUnwrap(AppVersion("1.0.2"))
        let published = try XCTUnwrap(AppVersion("v1.0.2"))
        XCTAssertFalse(published > current, "an identical tag must not prompt an update")
    }
}

final class UpdateCheckerParsingTests: XCTestCase {

    private func payload(tag: String, url: String) -> Data {
        Data("""
        {"tag_name":"\(tag)","name":"\(tag)","html_url":"\(url)","draft":false}
        """.utf8)
    }

    func testReadsTagAndPage() throws {
        let release = try XCTUnwrap(UpdateChecker.parseRelease(
            from: payload(tag: "v1.4.0", url: "https://github.com/ilmakio/paint-macos/releases/tag/v1.4.0")
        ))
        XCTAssertEqual(release.version.components, [1, 4, 0])
        XCTAssertEqual(release.pageURL.absoluteString,
                       "https://github.com/ilmakio/paint-macos/releases/tag/v1.4.0")
    }

    func testFallsBackToTheReleasesPageWhenTheURLIsMissing() throws {
        let data = Data(#"{"tag_name":"v2.0.0"}"#.utf8)
        let release = try XCTUnwrap(UpdateChecker.parseRelease(from: data))
        XCTAssertEqual(release.version.components, [2, 0, 0])
        XCTAssertTrue(release.pageURL.absoluteString.hasSuffix("/releases/latest"))
    }

    func testRejectsJunk() {
        XCTAssertNil(UpdateChecker.parseRelease(from: Data("not json".utf8)))
        XCTAssertNil(UpdateChecker.parseRelease(from: Data("{}".utf8)))
        XCTAssertNil(UpdateChecker.parseRelease(from: Data(#"{"tag_name":"nightly"}"#.utf8)))
    }
}
