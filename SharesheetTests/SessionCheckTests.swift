import Foundation
import Testing
import UserNotifications
@testable import Sharesheet
import SharesheetCore

@MainActor
struct SessionCheckTests {
    private final class Recorder {
        var delivered: [String] = []
    }

    private final class Delivery {
        var results = [true]
        var calls = 0
    }

    private static func makeDefaults() -> UserDefaults {
        let suite = "SessionCheckTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    private static func probe(_ id: String, _ name: String, _ status: SessionStatus) -> SessionCheck.Probe {
        .init(id: id, name: name, validate: { status })
    }

    @Test func reportsAnExpiredSessionOnlyOnce() async {
        let defaults = Self.makeDefaults()
        let recorder = Recorder()
        let check = SessionCheck(
            probes: [Self.probe("instagram", "Instagram", .expired)],
            defaults: defaults,
            deliver: { id, _ in recorder.delivered.append(id); return true })
        await check.run()
        await check.run()
        #expect(recorder.delivered == ["instagram"])
        #expect(defaults.bool(forKey: SessionCheck.notificationKey(for: "instagram")))
    }

    @Test func aValidCheckClearsTheMarkerSoALaterExpiryReportsAgain() async {
        let defaults = Self.makeDefaults()
        let recorder = Recorder()
        let valid = SessionCheck(
            probes: [Self.probe("x", "X", .valid)],
            defaults: defaults,
            deliver: { id, _ in recorder.delivered.append(id); return true })
        await valid.run()
        #expect(!defaults.bool(forKey: SessionCheck.notificationKey(for: "x")))
        let expired = SessionCheck(
            probes: [Self.probe("x", "X", .expired)],
            defaults: defaults,
            deliver: { id, _ in recorder.delivered.append(id); return true })
        await expired.run()
        #expect(recorder.delivered == ["x"])
    }

    @Test func unknownDoesNotReportOrChangeTheMarker() async {
        let defaults = Self.makeDefaults()
        defaults.set(true, forKey: SessionCheck.notificationKey(for: "facebook"))
        let recorder = Recorder()
        let check = SessionCheck(
            probes: [Self.probe("facebook", "Facebook", .unknown)],
            defaults: defaults,
            deliver: { id, _ in recorder.delivered.append(id); return true })
        await check.run()
        #expect(recorder.delivered.isEmpty)
        #expect(defaults.bool(forKey: SessionCheck.notificationKey(for: "facebook")))
    }

    @Test func noSessionClearsTheMarker() async {
        let defaults = Self.makeDefaults()
        defaults.set(true, forKey: SessionCheck.notificationKey(for: "x"))
        let check = SessionCheck(
            probes: [Self.probe("x", "X", .noSession)],
            defaults: defaults,
            deliver: { _, _ in true })
        await check.run()
        #expect(!defaults.bool(forKey: SessionCheck.notificationKey(for: "x")))
    }

    @Test func aFailedDeliveryIsRetried() async {
        let defaults = Self.makeDefaults()
        let delivery = Delivery()
        delivery.results = [false, true]
        let check = SessionCheck(
            probes: [Self.probe("instagram", "Instagram", .expired)],
            defaults: defaults,
            deliver: { _, _ in
                let result = delivery.results[delivery.calls]
                delivery.calls += 1
                return result
            })
        await check.run()
        #expect(delivery.calls == 1)
        #expect(!defaults.bool(forKey: SessionCheck.notificationKey(for: "instagram")))
        await check.run()
        #expect(delivery.calls == 2)
        #expect(defaults.bool(forKey: SessionCheck.notificationKey(for: "instagram")))
    }

    @Test func deliveryRequiresAuthorization() {
        #expect(SessionCheck.canDeliver(.authorized))
        #expect(SessionCheck.canDeliver(.provisional))
        #expect(SessionCheck.canDeliver(.ephemeral))
        #expect(!SessionCheck.canDeliver(.notDetermined))
        #expect(!SessionCheck.canDeliver(.denied))
    }
}
