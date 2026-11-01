import Foundation
import Testing
@testable import DiskIndexerKit

struct DiskIndexerKitTests {
    @Test func testDecodesServerJSON() throws {
        // Shapes copied from a real `diskindexer serve` response.
        let search = #"""
        {"results":[{"db":"/x/t.diskindex","id":5,"name":"film.mkv","path":"Test/Movies/Action/film.mkv","size":3,"modifiedAt":"2026-10-31T23:44:23Z","extension":"mkv","isDir":false,"diskLabel":"Test","collLabel":"Movies"}],"capped":false}
        """#
        let resp = try APIClient.decoder.decode(SearchResponse.self, from: Data(search.utf8))
        #expect(resp.results.count == 1)
        #expect(resp.results[0].fileID == 5)
        #expect(resp.results[0].id == "/x/t.diskindex#5")
        #expect(resp.results[0].extension == "mkv")

        let job = #"""
        {"id":"755c2be7250d404c","state":"done","request":{"db":"/x/t.diskindex","disk":"Test","mountPath":"/x/disk"},"startedAt":"2026-10-31T23:44:25.012181Z","finishedAt":"2026-10-31T23:44:25.014039Z","progress":{"phase":"sizes","added":0,"updated":0,"skipped":0,"total":0,"dirsTotal":3,"dirsDone":3},"stats":{"added":5,"updated":0,"deleted":0,"skipped":0,"elapsedMs":1}}
        """#
        let j = try APIClient.decoder.decode(Job.self, from: Data(job.utf8))
        #expect(j.state == .done)
        #expect(j.stats?.added == 5)
        #expect(j.fraction == 1)
    }

    @Test func testParseRFC3339() {
        #expect(parseRFC3339("2026-10-31T23:44:25Z") != nil)
        #expect(parseRFC3339("2026-10-31T23:44:25.012181Z") != nil)
        #expect(parseRFC3339("2026-10-31T19:44:25-04:00") != nil)
        #expect(parseRFC3339("yesterday") == nil)
    }

    @Test func testFormatSizeMatchesTUI() {
        #expect(Format.size(512) == "512B")
        #expect(Format.size(1024) == "1.0K")
        #expect(Format.size(1024 * 1024) == "1.0M")
        #expect(Format.size(1024 * 1024 * 1024) == "1.0G")
        #expect(Format.size(1024 * 1024 * 1024 * 1024) == "1.0T")
        #expect(Format.commas(1234567) == "1,234,567")
    }

    @Test func testProgressFraction() throws {
        var j = try APIClient.decoder.decode(Job.self, from: Data(#"""
        {"id":"a","state":"running","request":{"disk":"D","mountPath":"/m"},"startedAt":"2026-10-31T23:44:25Z","progress":{"phase":"indexing","added":25,"updated":0,"skipped":25,"total":200,"dirsTotal":0,"dirsDone":0}}
        """#.utf8))
        #expect(j.fraction == 0.25)
        j.progress.total = 0
        #expect(j.fraction == nil, "unknown total is indeterminate")
        #expect(Format.eta(processed: 50, total: 200, elapsed: 10) == "~30s left")
    }

    @Test func testMountPathGuess() {
        func coll(_ root: String) -> Collection {
            Collection(db: "d", id: 1, diskLabel: "D", label: "x", rootPath: root, lastIndexedAt: nil)
        }
        let auto = DiskNode(label: "D", disks: [], collections: [coll("/media/a/Movies"), coll("/media/a/Music")])
        #expect(auto.guessedMountPath == "/media/a")
        let manual = DiskNode(label: "D", disks: [], collections: [coll("/media/a/Movies"), coll("/srv/other")])
        #expect(manual.guessedMountPath == nil)
    }

    @Test func testIndexDraftRules() {
        let node = DiskNode(label: "D", disks: [], collections: [])

        var add = IndexDraft(addingTo: node)
        #expect(!add.isValid, "needs a collection")
        add.collections[0] = EditableCollection(label: "Music", path: "/srv/Music")
        add.mountPath = "/should/be/ignored"
        #expect(add.isValid)
        #expect(add.request.mountPath == "")
        #expect(add.request.collections == [CollectionSpec(label: "Music", rootPath: "/srv/Music")])
        #expect(add.request.force == nil)
        #expect(add.title == "Add Collection to \u{201C}D\u{201D}")

        var new = IndexDraft()
        new.disk = "D"
        #expect(!new.isValid, "auto collections need a mount path")
        new.mountPath = "/media/d"
        #expect(new.isValid)
        new.autoCollections = false
        #expect(!new.isValid, "manual mode needs a collection")
        new.collections = [EditableCollection(label: "A", path: "/a")]
        new.mountPath = ""
        #expect(new.isValid, "mount path is optional with listed collections")
    }

    @Test func testCollectionDragPayload() {
        let c = Collection(db: "/home/me/a@b.diskindex", id: 42, diskLabel: "D", label: "Photos", rootPath: "/x", lastIndexedAt: nil)
        let parsed = CollectionDrag.parse(CollectionDrag.payload(c))
        #expect(parsed?.id == 42)
        #expect(parsed?.db == "/home/me/a@b.diskindex")
        #expect(CollectionDrag.parse("some dropped text") == nil)
        #expect(CollectionDrag.parse("diskindexer-collection:x@db") == nil)
    }
}
