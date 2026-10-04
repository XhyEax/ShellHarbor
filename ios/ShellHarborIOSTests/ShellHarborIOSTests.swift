import XCTest
import NIOCore
import NIOEmbedded
@testable import ShellHarborIOS

final class ShellHarborIOSTests: XCTestCase {
    func testPortForwardRulesGroupByRemoteAndKeepUngroupedRules() {
        let remoteA = UUID()
        let remoteB = UUID()
        let sessionA1 = UUID()
        let sessionA2 = UUID()
        let sessionB = UUID()
        var first = MobilePortForwardRule()
        first.selectedSessionID = sessionA1
        var second = MobilePortForwardRule()
        second.selectedSessionID = sessionB
        var third = MobilePortForwardRule()
        third.selectedSessionID = sessionA2
        let ungrouped = MobilePortForwardRule()

        let groups = MobilePortForwardPresentation.groups(
            rules: [first, second, third, ungrouped],
            sessionRemoteIDs: [
                sessionA1: remoteA,
                sessionA2: remoteA,
                sessionB: remoteB
            ]
        )

        XCTAssertEqual(groups.map(\.remoteID), [remoteA, remoteB, nil])
        XCTAssertEqual(groups[0].ruleIDs, [first.id, third.id])
        XCTAssertEqual(groups[1].ruleIDs, [second.id])
        XCTAssertEqual(groups[2].ruleIDs, [ungrouped.id])
    }

    func testEmbeddedBrowserUsesLoopbackForAllInterfaceBinding() {
        var rule = MobilePortForwardRule()
        rule.bindHost = "0.0.0.0"
        XCTAssertEqual(
            MobilePortForwardPresentation.browserURL(
                for: rule,
                listeningPort: 8_080
            )?.absoluteString,
            "http://127.0.0.1:8080/"
        )
        XCTAssertNil(
            MobilePortForwardPresentation.browserURL(
                for: rule,
                listeningPort: 70_000
            )
        )
    }

    @MainActor
    func testPortForwardRulesPersistAndStartAllReportsMissingSession() {
        let suiteName = "ShellHarborIOSTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = MobilePortForwardStore(defaults: defaults)
        var rule = MobilePortForwardRule()
        rule.selectedSessionID = UUID()
        var secondRule = MobilePortForwardRule()
        secondRule.selectedSessionID = UUID()
        secondRule.listenPort = 8_081
        store.rules = [rule, secondRule]

        let restored = MobilePortForwardStore(defaults: defaults)
        XCTAssertEqual(restored.rules, [rule, secondRule])
        restored.startAll(sessions: [])
        XCTAssertEqual(
            restored.statuses[rule.id],
            .failed(MobilePortForwardError.sessionNotConnected.localizedDescription)
        )
        XCTAssertEqual(
            restored.statuses[secondRule.id],
            .failed(MobilePortForwardError.sessionNotConnected.localizedDescription)
        )
    }

    func testPortForwardGlueCarriesByteBuffersInBothDirections() throws {
        let (leftGlue, rightGlue) = MobilePortForwardGlue.matchedPair()
        let left = EmbeddedChannel(handler: leftGlue)
        let right = EmbeddedChannel(handler: rightGlue)
        defer {
            _ = try? left.finish()
            _ = try? right.finish()
        }

        // A masked WebSocket binary frame includes arbitrary bytes (including
        // NUL). The forwarder must remain a transparent ByteBuffer pipe.
        let requestBytes: [UInt8] = [
            0x82, 0x85, 0x37, 0xFA, 0x21, 0x3D,
            0x7F, 0x9F, 0x4D, 0x51, 0x58
        ]
        var request = left.allocator.buffer(capacity: requestBytes.count)
        request.writeBytes(requestBytes)
        _ = try left.writeInbound(request)
        right.embeddedEventLoop.run()
        var forwardedRequest = try XCTUnwrap(
            right.readOutbound(as: ByteBuffer.self)
        )
        XCTAssertEqual(forwardedRequest.readBytes(length: requestBytes.count), requestBytes)

        let responseBytes: [UInt8] = [0x82, 0x03, 0x00, 0xFF, 0x7F]
        var response = right.allocator.buffer(capacity: responseBytes.count)
        response.writeBytes(responseBytes)
        _ = try right.writeInbound(response)
        left.embeddedEventLoop.run()
        var forwardedResponse = try XCTUnwrap(
            left.readOutbound(as: ByteBuffer.self)
        )
        XCTAssertEqual(
            forwardedResponse.readBytes(length: responseBytes.count),
            responseBytes
        )
    }

    func testEachSessionRestorationRoundTripsItsOwnState() throws {
        let firstID = UUID()
        let secondID = UUID()
        var firstRemote = MobileRemoteProfile()
        firstRemote.id = UUID()
        firstRemote.name = "First"
        var secondRemote = MobileRemoteProfile()
        secondRemote.id = UUID()
        secondRemote.name = "Second"
        let records = [
            MobileSessionRestoration(
                sessionID: firstID,
                remote: firstRemote,
                jumpRemote: nil,
                selectedView: "terminal",
                remotePath: "/srv/first",
                localPath: "Documents/First",
                terminalTitle: "first-shell",
                terminalDirectory: "/srv/first",
                terminalHistory: Data("first-history".utf8),
                pendingCommand: "echo first",
                moshState: Data([1, 2, 3]),
                moshServerPort: 60_001,
                moshKey: "encrypted-first-key",
                shouldReconnect: true,
                sessionNumber: 1,
                nameSuffix: "work"
            ),
            MobileSessionRestoration(
                sessionID: secondID,
                remote: secondRemote,
                jumpRemote: nil,
                selectedView: "files",
                remotePath: "/srv/second",
                localPath: "Documents/Second",
                terminalTitle: "second-shell",
                terminalDirectory: "/srv/second",
                terminalHistory: Data("second-history".utf8),
                pendingCommand: nil,
                moshState: Data(),
                moshServerPort: nil,
                moshKey: nil,
                shouldReconnect: false,
                sessionNumber: 2,
                nameSuffix: nil
            )
        ]

        let decoded = try JSONDecoder().decode(
            [MobileSessionRestoration].self,
            from: JSONEncoder().encode(records)
        )

        XCTAssertEqual(decoded.map(\.sessionID), [firstID, secondID])
        XCTAssertEqual(decoded.map(\.terminalHistory), records.map(\.terminalHistory))
        XCTAssertEqual(decoded.map(\.remotePath), ["/srv/first", "/srv/second"])
        XCTAssertEqual(decoded.map(\.localPath), ["Documents/First", "Documents/Second"])
        XCTAssertEqual(decoded[0].pendingCommand, "echo first")
        XCTAssertTrue(decoded[0].shouldReconnect)
        XCTAssertFalse(decoded[1].shouldReconnect)
    }
}
