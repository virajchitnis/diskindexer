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

    @Test func testJobErrorsAndPhases() throws {
        // A finished job with unreadable paths, as the server sends it.
        let done = try APIClient.decoder.decode(Job.self, from: Data(#"""
        {"id":"j","state":"done","request":{"disk":"D","mountPath":"/m"},"startedAt":"2026-11-01T00:00:00Z","progress":{"phase":"sizes","added":0,"updated":0,"skipped":5,"total":8,"errors":1,"deleting":0,"dirsTotal":3,"dirsDone":3},"stats":{"added":0,"updated":0,"deleted":0,"skipped":5,"elapsedMs":1,"errorCount":1,"errors":[{"path":"/m/Photos/locked","error":"permission denied"}]}}
        """#.utf8))
        #expect(done.errorCount == 1)
        #expect(done.phaseTitle == "Done, 1 unreadable")
        #expect(done.stats?.errors?.first?.path == "/m/Photos/locked")

        // An older server without the new fields still decodes.
        var running = try APIClient.decoder.decode(Job.self, from: Data(#"""
        {"id":"j","state":"running","request":{"disk":"D","mountPath":"/m"},"startedAt":"2026-11-01T00:00:00Z","progress":{"phase":"loading","added":0,"updated":0,"skipped":0,"total":0,"dirsTotal":0,"dirsDone":0}}
        """#.utf8))
        #expect(running.errorCount == 0)
        #expect(running.phaseTitle == "Loading existing index")
        #expect(running.fraction == nil)
        running.progress.phase = "deleting"
        running.progress.deleting = 1200
        #expect(running.phaseTitle == "Removing 1,200 files no longer on disk")
        running.progress.phase = "root"
        #expect(running.phaseTitle == "Indexing files at the top of the disk")
    }

    @Test func testSSHFailureClassification() {
        // Messages as macOS's ssh prints them.
        #expect(SSHFailureKind.classify("ssh: Could not resolve hostname enterprise: nodename nor servname provided, or not known") == .network)
        #expect(SSHFailureKind.classify("ssh: connect to host 100.64.0.5 port 22: Operation timed out") == .network)
        #expect(SSHFailureKind.classify("ssh: connect to host enterprise port 22: No route to host") == .network)
        #expect(SSHFailureKind.classify("ssh: connect to host enterprise port 22: Connection refused") == .network)
        #expect(SSHFailureKind.classify("Connection closed by 100.64.0.5 port 22") == .network)
        #expect(SSHFailureKind.classify("kex_exchange_identification: read: Connection reset by peer") == .network)
        #expect(SSHFailureKind.classify("Timeout, server enterprise not responding.") == .network)
        #expect(SSHFailureKind.classify("Host key verification failed.") == .hostKey)
        #expect(SSHFailureKind.classify("@@@ WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED! @@@\nHost key verification failed.") == .hostKey)
        #expect(SSHFailureKind.classify("viraj@enterprise: Permission denied (publickey,password).") == .auth)
        #expect(SSHFailureKind.classify("something unexpected") == .other)
        #expect(SSHFailureKind.network.isTransient && SSHFailureKind.other.isTransient)
        #expect(!SSHFailureKind.auth.isTransient && !SSHFailureKind.hostKey.isTransient)

        #expect(ConnectionFailure("x", isTransient: true).isTransientConnectionError)
        #expect(!ConnectionFailure("x", isTransient: false).isTransientConnectionError)
        #expect(URLError(.cannotConnectToHost).isTransientConnectionError)
        #expect(!APIError(status: 500, message: "boom").isTransientConnectionError)
    }

    @Test func testStoppedJobsDontShowAFullBar() throws {
        var j = try APIClient.decoder.decode(Job.self, from: Data(#"""
        {"id":"a","state":"running","request":{"disk":"D","mountPath":"/m"},"startedAt":"2026-11-01T00:00:00Z","progress":{"phase":"indexing","added":25,"updated":0,"skipped":25,"total":200,"dirsTotal":0,"dirsDone":0}}
        """#.utf8))
        j.state = .interrupted
        #expect(j.fraction == 0.25)
        #expect(j.phaseTitle == "Interrupted")
        j.progress.total = 0
        #expect(j.fraction == 0)
        j.state = .done
        #expect(j.fraction == 1)
    }
}
