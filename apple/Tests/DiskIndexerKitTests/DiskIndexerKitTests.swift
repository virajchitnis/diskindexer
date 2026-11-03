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

    @Test func testIndexDraftExcludes() {
        let disk = Disk(db: "d", id: 1, label: "D", description: "", createdAt: .now,
                        lastIndexedAt: nil, excludes: [".snapshots", "lost+found"])
        let node = DiskNode(label: "D", disks: [disk], collections: [])

        // Reindex and Add Collection pre-fill the disk's remembered excludes.
        var re = IndexDraft(node: node)
        #expect(re.excludes == ".snapshots, lost+found")
        #expect(re.request.excludes == [".snapshots", "lost+found"])
        #expect(re.request.noDefaultExcludes == nil)
        re.useDefaultExcludes = false
        #expect(re.request.noDefaultExcludes == true)

        var add = IndexDraft(addingTo: node)
        #expect(add.excludes == ".snapshots, lost+found")
        // Clearing the field is sent as [] so the disk's list is cleared,
        // not silently reused.
        add.excludes = " , "
        #expect(add.request.excludes == [])

        // A new disk starts empty.
        #expect(IndexDraft().request.excludes == [])
    }

    @Test func testServerVersion() throws {
        let tagged = try #require(ServerVersion("v1.3.1"))
        let ahead = try #require(ServerVersion("v1.3.1-20-ge0ee61b"))
        let dirty = try #require(ServerVersion("1.3.1-20-ge0ee61b-dirty"))
        let next = try #require(ServerVersion("v1.4.0"))
        #expect(tagged < ahead)
        #expect(!(ahead < dirty) && !(dirty < ahead), "dirty doesn't change the version")
        #expect(ahead < next)
        #expect(ServerVersion("v1.10.0")! > ServerVersion("v1.9.9")!)
        #expect(ServerVersion("dev") == nil)
        #expect(ServerVersion("e0ee61b") == nil, "untagged builds don't compare")
        #expect(ahead.description == "1.3.1+20")

        #expect(AppModel.updateAvailable(server: "v1.3.1", bundled: "1.3.1-20-gabc")?.available == "1.3.1-20-gabc")
        #expect(AppModel.updateAvailable(server: "v1.3.1-20-gabc", bundled: "1.3.1-20-gabc-dirty") == nil)
        #expect(AppModel.updateAvailable(server: "v1.4.0", bundled: "1.3.1") == nil, "never downgrade")
        #expect(AppModel.updateAvailable(server: "dev", bundled: "1.3.1") == nil)
        #expect(AppModel.updateAvailable(server: "v1.3.1", bundled: nil) == nil)
    }

    @Test func testFirstReachable() async throws {
        let unreachable = ConnectionFailure("no route", isTransient: true, reason: .unreachable)

        // Falls through unreachable addresses to the first that works.
        var tried: [String] = []
        let r = try await firstReachable(["lan", "tailscale", "public"]) { host, isLast in
            tried.append(host)
            if host == "lan" { throw unreachable }
            return isLast
        }
        #expect(r.address == "tailscale")
        #expect(r.value == false)
        #expect(tried == ["lan", "tailscale"])

        // A reachable server that refuses stops the search: every address
        // would say the same.
        tried = []
        await #expect(throws: ConnectionFailure.self) {
            _ = try await firstReachable(["lan", "tailscale"]) { host, _ in
                tried.append(host)
                throw ConnectionFailure("refused the login", isTransient: false)
            }
        }
        #expect(tried == ["lan"])

        // None reachable: one transient error listing each address.
        do {
            let _: (address: String, value: Bool) = try await firstReachable(["lan", "tailscale"]) { _, _ in throw unreachable }
            Issue.record("expected a failure")
        } catch let f as ConnectionFailure {
            #expect(f.isTransient)
            #expect(f.reason == .unreachable)
            #expect(f.message == "lan: no route\ntailscale: no route")
        }
    }

    @Test func testBackgroundRunNote() throws {
        func info(_ json: String) throws -> ServerInfo {
            try APIClient.decoder.decode(ServerInfo.self, from: Data(json.utf8))
        }
        let base = #""apiVersion":1,"version":"v1","hostname":"h","defaultDb":"/d","dbs":[]"#
        let linger = try info(#"{\#(base),"os":"linux","user":"viraj","persistent":true}"#)
        let noLinger = try info(#"{\#(base),"os":"linux","user":"viraj","persistent":false}"#)
        let macOnDemand = try info(#"{\#(base),"os":"darwin","user":"v","persistent":false}"#)
        let old = try info(#"{\#(base),"os":"linux"}"#)

        #expect(backgroundRunNote(info: linger, serverName: "enterprise", isLocal: false) == nil)
        #expect(backgroundRunNote(info: old, serverName: "enterprise", isLocal: false) == nil, "unknown: no warning")
        let note = try #require(backgroundRunNote(info: noLinger, serverName: "enterprise", isLocal: false))
        #expect(note.contains("stops if your Mac disconnects"))
        #expect(note.contains("sudo loginctl enable-linger viraj"))
        let mac = try #require(backgroundRunNote(info: macOnDemand, serverName: "studio", isLocal: false))
        #expect(!mac.contains("loginctl"), "no linger on macOS")
        #expect(backgroundRunNote(info: noLinger, serverName: "x", isLocal: true)?.contains("quitting it stops the run") == true)
    }

    @Test func testHostKeyProblemParsing() throws {
        // `ssh -v -o BatchMode=yes` for a key this Mac has never seen.
        let unknownLog = """
            debug1: Connecting to 192.168.68.69 [192.168.68.69] port 22.
            debug1: Server host key: ssh-ed25519 SHA256:/MZvK8JUs309RSRVG70VCb0Uic+dBPslcfyFLmxvwfE
            debug1: checking without port identifier
            Host key verification failed.
            """
        let unknown = try #require(HostKeyProblem.parse(unknownLog, address: "192.168.68.69"))
        #expect(unknown.kind == .unknown)
        #expect(unknown.keyType == "ED25519")
        #expect(unknown.fingerprint == "SHA256:/MZvK8JUs309RSRVG70VCb0Uic+dBPslcfyFLmxvwfE")
        #expect(unknown.offending == nil)
        #expect(!unknown.needsConfirmation)
        #expect(unknown.summary.contains("hasn\u{2019}t connected to 192.168.68.69"))

        // And for a key that conflicts with a trusted one.
        let changedLog = """
            debug1: Server host key: ecdsa-sha2-nistp256 SHA256:newkey
            @    WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED!     @
            Add correct host key in /Users/me/.ssh/known_hosts to get rid of this message.
            Offending ECDSA key in /Users/me/.ssh/known_hosts:32
            Host key verification failed.
            """
        var changed = try #require(HostKeyProblem.parse(changedLog, address: "nas.local"))
        #expect(changed.kind == .changed)
        #expect(changed.keyType == "ECDSA")
        #expect(changed.offending == HostKeyProblem.Entry(file: "/Users/me/.ssh/known_hosts", line: 32))
        #expect(changed.needsConfirmation, "nothing vouches for the new key")
        #expect(changed.summary.contains("intercepting"))
        changed.matchingAddresses = ["nas.example.com"]
        #expect(!changed.needsConfirmation)
        #expect(changed.summary.contains("already trust for nas.example.com"))

        #expect(HostKeyProblem.parse("ssh: connect to host x port 22: Connection refused", address: "x") == nil)
        #expect(HostKeyProblem.keyTypeName("rsa-sha2-512") == "RSA")
        #expect(HostKeyProblem.keyTypeName("sk-ssh-ed25519@openssh.com") == "ED25519")
        #expect(HostKeyProblem.keyTypeName("other") == "OTHER")
    }

    @Test func testSchedules() throws {
        let json = #"""
        {"db":"/x/t.diskindex","id":3,"disk":"Seagate","collection":"Photos","path":"/srv/copy","intervalHours":168,"at":"03:00","enabled":true,"createdAt":"2026-11-01T10:00:00Z","lastRunAt":"2026-11-02T03:00:00Z","lastStatus":"skipped","lastMessage":"Nothing is mounted at /mnt/seagate.","nextRunAt":"2026-11-09T03:00:00Z"}
        """#
        let s = try APIClient.decoder.decode(Schedule.self, from: Data(json.utf8))
        #expect(s.id == "/x/t.diskindex#3")
        #expect(s.isCollection)
        #expect(s.targetTitle == "Seagate / Photos")
        #expect(s.intervalDescription(timeZone: "CET") == "Every week at 03:00 CET")
        #expect(s.lastStatusTitle == "Skipped")
        #expect(s.lastRunNeedsAttention)

        #expect(Format.interval(hours: 1) == "Every hour")
        #expect(Format.interval(hours: 6) == "Every 6 hours")
        #expect(Format.interval(hours: 24) == "Every day")
        #expect(Format.interval(hours: 48) == "Every 2 days")
        #expect(Format.interval(hours: 336) == "Every 2 weeks")

        var t = s
        for (status, title) in [("running", "Running"), ("done", "Done"), ("failed", "Failed"),
                                ("cancelled", "Cancelled"), ("interrupted", "Interrupted"), ("odd", "Odd")] {
            t.lastStatus = status
            #expect(t.lastStatusTitle == title)
        }
        t.lastStatus = nil
        #expect(t.lastStatusTitle == nil)
        #expect(!t.lastRunNeedsAttention)
        t.collection = nil
        t.at = nil
        #expect(t.targetTitle == "Seagate")
        #expect(t.intervalDescription() == "Every week")

        // Editing keeps the interval's unit and time.
        var d = ScheduleDraft(editing: s, savedLocation: "/mnt/seagate/Photos")
        #expect(d.unit == .weeks && d.every == 1)
        #expect(d.at == "03:00")
        #expect(d.request.path == "/srv/copy")
        #expect(d.title == "Reindex \u{201C}Photos\u{201D} on \u{201C}Seagate\u{201D}")
        // Reading from the saved location sends no path.
        d.path = "/mnt/seagate/Photos"
        #expect(d.request.path == nil)
        d.unit = .hours
        d.every = 6
        #expect(!d.timeApplies && d.at == nil)
        #expect(d.request.intervalHours == 6)
        #expect(d.isValid)
        #expect(ScheduleDraft.Unit.weeks.title(2) == "weeks")
        #expect(ScheduleDraft.Unit.hours.title(1) == "hour")
        #expect(ScheduleDraft.Unit.days.title(1) == "day")
        #expect(ScheduleDraft.parse("25:00") == nil)

        t.intervalHours = 36
        let h = ScheduleDraft(editing: t)
        #expect(h.unit == .hours && h.every == 36 && !h.useTime)
        t.intervalHours = 48
        #expect(ScheduleDraft(editing: t).unit == .days)

        // A new disk schedule needs a mount path; it starts from the guess.
        let disk = Disk(db: "/x/t.diskindex", id: 1, label: "Seagate", description: "", createdAt: Date())
        let coll = Collection(db: "/x/t.diskindex", id: 2, diskLabel: "Seagate", label: "Photos", rootPath: "/mnt/seagate/Photos")
        let node = DiskNode(label: "Seagate", disks: [disk], collections: [coll])
        var nd = ScheduleDraft(node: node)
        #expect(nd.path == "/mnt/seagate")
        #expect(nd.title == "Reindex \u{201C}Seagate\u{201D}")
        #expect(nd.request.at == "03:00" && nd.request.intervalHours == 24 && nd.request.db == "/x/t.diskindex")
        nd.path = " "
        #expect(!nd.isValid)
        let cd = ScheduleDraft(node: node, collection: coll)
        #expect(cd.isValid && cd.request.path == nil && cd.request.collection == "Photos")
    }

    @Test func testScheduleRunNote() throws {
        func info(_ extra: String) throws -> ServerInfo {
            let json = #"{"apiVersion":1,"version":"v1","hostname":"h","os":"linux","defaultDb":"/d","dbs":["/d"],"user":"me""# + extra + "}"
            return try APIClient.decoder.decode(ServerInfo.self, from: Data(json.utf8))
        }
        #expect(scheduleRunNote(info: nil, serverName: "e") == "")
        #expect(try scheduleRunNote(info: info(#","scheduler":false"#), serverName: "e").contains("don\u{2019}t run there"))
        #expect(try scheduleRunNote(info: info(#","scheduler":true,"persistent":true"#), serverName: "e").contains("around the clock, whether"))
        #expect(try scheduleRunNote(info: info(#","scheduler":true,"persistent":false"#), serverName: "e").contains("loginctl enable-linger me"))
        #expect(try scheduleRunNote(info: info(#","scheduler":true"#), serverName: "e") == "Schedules run while diskindexer is running on e.")
    }
}
