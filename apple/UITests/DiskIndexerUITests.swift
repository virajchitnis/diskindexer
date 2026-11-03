import XCTest

// End-to-end tests: the real app, driven through its UI, against a real
// `diskindexer serve` in local mode. Each test builds fixture disks on disk,
// indexes them with the CLI, and launches the app pointed at that index.
//
// The CLI binary comes from $DISKINDEXER_BIN; CI passes it to the test runner
// as TEST_RUNNER_DISKINDEXER_BIN (xcodebuild strips the prefix).

/// Fixture disks:
///   Disk A: Photos/beach.jpg, Photos/2019/party.jpg, Music/song.flac
///   Disk B: Backup/beach.jpg (same size as Disk A's: a duplicate), Music/other.flac
///   New:    Docs/readme.txt (not indexed; for the Index Disk sheet)
final class Fixture {
    let root: URL
    let db: String
    let bin: String

    init() throws {
        guard let bin = ProcessInfo.processInfo.environment["DISKINDEXER_BIN"],
              FileManager.default.isExecutableFile(atPath: bin) else {
            throw XCTSkip("Set DISKINDEXER_BIN (TEST_RUNNER_DISKINDEXER_BIN for xcodebuild) to the diskindexer binary")
        }
        self.bin = bin
        root = FileManager.default.temporaryDirectory.appendingPathComponent("di-e2e-\(UUID().uuidString)")
        db = root.appendingPathComponent("test.diskindex").path

        try write([
            "DiskA/Photos/beach.jpg": "sand and sea",
            "DiskA/Photos/2019/party.jpg": "party!",
            "DiskA/Music/song.flac": "la la",
            "DiskB/Backup/beach.jpg": "sand and sea",
            "DiskB/Music/other.flac": "dum",
            "New/Docs/readme.txt": "hello",
        ])
        try index(path("DiskA"), disk: "Disk A")
        try index(path("DiskB"), disk: "Disk B")
    }

    func path(_ rel: String) -> String { root.appendingPathComponent(rel).path }

    private func write(_ files: [String: String]) throws {
        for (rel, content) in files {
            let url = root.appendingPathComponent(rel)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(content.utf8).write(to: url)
        }
    }

    private func index(_ mount: String, disk: String) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: bin)
        p.arguments = ["index", mount, "--disk", disk, "--db", db]
        p.standardOutput = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        XCTAssertEqual(p.terminationStatus, 0, "indexing \(disk)")
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }
}

final class DiskIndexerUITests: XCTestCase {
    var fixture: Fixture!
    var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        fixture = try Fixture()
        app = launch()
    }

    override func tearDown() {
        app?.terminate()
        fixture = nil
    }

    /// Prints the app's element tree to the log on the first failure, so CI
    /// failures can be diagnosed without opening the result bundle.
    private var dumpedTree = false
    override func record(_ issue: XCTIssue) {
        if !dumpedTree, let app, app.state == .runningForeground || app.state == .runningBackground {
            dumpedTree = true
            print("── UI element tree at failure ──\n\(app.debugDescription)")
        }
        super.record(issue)
    }

    private func launch(bin: String? = nil) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment = [
            "DISKINDEXER_BIN": bin ?? fixture.bin,
            "DISKINDEXER_DB": fixture.db,
        ]
        // Local mode, and no restored windows from a previous run.
        app.launchArguments = ["-selectedConnection", "local", "-ApplePersistenceIgnoreState", "YES"]
        app.launch()
        return app
    }

    // MARK: Helpers

    // Both the sidebar List and the results Table are exposed as outlines.
    private var window: XCUIElement { app.windows.firstMatch }
    private var sidebar: XCUIElement { window.outlines["Sidebar"] }
    private var results: XCUIElement { window.outlines["results"] }

    /// A sidebar row by its text. Disk rows are DisclosureGroup labels,
    /// which macOS exposes as the disclosure triangle's title rather than as
    /// static text, so match any element by label, title or value.
    private func sidebarItem(_ label: String) -> XCUIElement {
        sidebar.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@ OR title == %@ OR value == %@", label, label, label))
            .firstMatch
    }

    /// Clicks the matching button that can actually be clicked, e.g. the
    /// alert's "Rename" rather than another element with that name. Only the
    /// window is searched: the Touch Bar can mirror buttons, and those can't
    /// be clicked.
    private func clickButton(_ name: String) {
        clickHittable(window.buttons, name)
    }

    /// Drags `source` onto `target` until `expected` (the confirmation or
    /// the clash alert) appears. A drag on a busy CI runner occasionally
    /// doesn't register as a drop, so retry a couple of times.
    @discardableResult
    private func drag(_ source: XCUIElement, onto target: XCUIElement, expecting expected: XCUIElement) -> Bool {
        for _ in 0..<3 {
            source.click(forDuration: 1.0, thenDragTo: target)
            if expected.waitForExistence(timeout: 5) { return true }
        }
        return false
    }

    private func clickHittable(_ query: XCUIElementQuery, _ name: String) {
        let matches = query.matching(identifier: name)
        XCTAssertTrue(matches.firstMatch.waitForExistence(timeout: 5), name)
        for i in 0..<matches.count where matches.element(boundBy: i).isHittable {
            matches.element(boundBy: i).click()
            return
        }
        XCTFail("no clickable \(name)")
    }

    /// Expands a disk in the sidebar to show its collections.
    private func expand(_ disk: String) {
        let row = sidebar.outlineRows
            .containing(NSPredicate(format: "label == %@ OR title == %@ OR value == %@", disk, disk, disk))
            .firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 20), "sidebar row for \(disk)")
        let triangle = row.disclosureTriangles.firstMatch
        if triangle.exists, (triangle.value as? Int ?? 0) == 0 {
            triangle.click()
        }
    }

    private func collection(_ label: String, under disk: String) -> XCUIElement {
        expand(disk)
        return sidebarItem(label)
    }

    private func search(_ text: String) {
        let field = app.searchFields.firstMatch
        if !field.exists {
            window.buttons["Search"].firstMatch.click()
        }
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.click()
        field.typeKey("a", modifierFlags: .command)
        field.typeText(text)
    }

    private func resultCell(_ name: String) -> XCUIElement {
        results.staticTexts[name].firstMatch
    }

    private func waitGone(_ element: XCUIElement, timeout: TimeInterval = 10) -> Bool {
        let gone = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: element)
        return XCTWaiter.wait(for: [gone], timeout: timeout) == .completed
    }

    // MARK: Tests

    func testShowsDisksAndResults() {
        XCTAssertTrue(sidebarItem("Disk A").waitForExistence(timeout: 20))
        XCTAssertTrue(sidebarItem("Disk B").exists)
        XCTAssertTrue(resultCell("beach.jpg").waitForExistence(timeout: 10))
        let count = app.staticTexts["status.count"]
        XCTAssertTrue(count.waitForExistence(timeout: 5))
        XCTAssertTrue((count.value as? String ?? count.label).contains("results"))
    }

    func testSearchAndFilters() {
        XCTAssertTrue(sidebarItem("Disk A").waitForExistence(timeout: 20))
        XCTAssertTrue(resultCell("beach.jpg").waitForExistence(timeout: 10))

        // Type filter first: once the search field expands, a narrow window
        // moves the filter into the toolbar's overflow menu.
        window.radioButtons["Folders"].click()
        XCTAssertTrue(waitGone(resultCell("beach.jpg")))
        XCTAssertTrue(resultCell("Photos").waitForExistence(timeout: 5))
        window.radioButtons["All"].click()
        XCTAssertTrue(resultCell("beach.jpg").waitForExistence(timeout: 5))

        search("party")
        XCTAssertTrue(resultCell("party.jpg").waitForExistence(timeout: 5))
        XCTAssertTrue(waitGone(resultCell("song.flac")))

        search("beach")
        XCTAssertTrue(resultCell("beach.jpg").waitForExistence(timeout: 5))
        // Two copies (Disk A and Disk B) of the same name and size.
        XCTAssertEqual(results.staticTexts.matching(identifier: "beach.jpg").count, 2)

        // Sidebar collection filter: only Disk B's Backup.
        collection("Backup", under: "Disk B").click()
        XCTAssertTrue(resultCell("beach.jpg").waitForExistence(timeout: 5))
        XCTAssertEqual(results.staticTexts.matching(identifier: "beach.jpg").count, 1)
    }

    func testIndexDiskFromSheet() {
        XCTAssertTrue(sidebarItem("Disk A").waitForExistence(timeout: 20))
        window.buttons["Index Disk"].firstMatch.click()

        let label = app.textFields["index.diskLabel"]
        XCTAssertTrue(label.waitForExistence(timeout: 5))
        label.click()
        label.typeText("New Disk")
        let mount = app.textFields["index.mountPath"]
        mount.click()
        mount.typeText(fixture.path("New"))
        app.buttons["index.start"].click()

        // The job runs and the new disk appears in the sidebar when it's done.
        XCTAssertTrue(sidebarItem("New Disk").waitForExistence(timeout: 30))
        search("readme")
        XCTAssertTrue(resultCell("readme.txt").waitForExistence(timeout: 10))
    }

    func testRenameCollection() {
        let photos = collection("Photos", under: "Disk A")
        XCTAssertTrue(photos.waitForExistence(timeout: 20))
        photos.rightClick()
        app.menuItems["Rename…"].click()

        // The alert's text field is focused with the current name.
        app.typeKey("a", modifierFlags: .command)
        app.typeText("Pictures")
        clickButton("Rename")

        XCTAssertTrue(sidebarItem("Pictures").waitForExistence(timeout: 10))
        XCTAssertTrue(waitGone(sidebarItem("Photos")))
    }

    func testMoveCollectionByDragThenUndo() {
        let photos = collection("Photos", under: "Disk A")
        XCTAssertTrue(photos.waitForExistence(timeout: 20))
        let diskB = sidebarItem("Disk B")

        XCTAssertTrue(drag(photos, onto: diskB, expecting: window.buttons["Move"]), "confirmation before moving")
        clickButton("Move")

        // Filter to the moved collection (no typing, which would put "Undo
        // Typing" on top of the undo stack): every row is now on Disk B.
        sidebarItem("Photos").click()
        XCTAssertTrue(resultCell("party.jpg").waitForExistence(timeout: 10))
        XCTAssertTrue(results.staticTexts["Disk B"].waitForExistence(timeout: 10))
        XCTAssertFalse(results.staticTexts["Disk A"].exists)

        // Undo puts it back on Disk A; the filter follows it.
        // SwiftUI's Edit menu shows plain "Undo" (no action name); nothing
        // else was done since the move, so it undoes the move.
        app.menuBars.menuBarItems["Edit"].click()
        app.menuItems["undo:"].click()
        XCTAssertTrue(results.staticTexts["Disk A"].waitForExistence(timeout: 10))
        XCTAssertTrue(waitGone(results.staticTexts["Disk B"]))
    }

    func testMoveOntoNameClashExplains() {
        let music = collection("Music", under: "Disk A")
        XCTAssertTrue(music.waitForExistence(timeout: 20))

        // Disk B already has a Music collection: explained, not merged.
        XCTAssertTrue(drag(music, onto: sidebarItem("Disk B"), expecting: window.buttons["OK"]))
        XCTAssertFalse(window.buttons["Move"].exists)
        clickButton("OK")
    }

    func testCouldNotStartServer() {
        app.terminate()
        app = launch(bin: "/nonexistent/diskindexer")
        // A missing binary is something to fix, not to retry.
        XCTAssertTrue(app.staticTexts["Couldn't connect"].waitForExistence(timeout: 20))
        XCTAssertTrue(app.buttons["Try Again"].exists)
    }
}
