// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import Foundation

/// A microphone left silent with nothing claiming it, extracted from
/// production. The app cannot tell its own forgotten mute from one made in
/// System Settings, so it never opens anything by itself: it notices, offers,
/// and opens only when asked (issue #1568).
enum MicMuteStrandedContract {
    /// The production bodies name CoreAudio's types; here they stand for the
    /// fake devices above.
    typealias AudioDeviceID = Int
    typealias InputDevice = Device

    struct Device {
        var id: Int
        var uid: String
        var muteSwitch: Int?
        /// Devices without a mute switch fall back to the input level, which
        /// is the other way a sweep can silence one.
        var volume: Float? = 0.8
        /// A driver that takes the write and keeps its level, which must never
        /// be recorded as muted.
        var ignoresWrites = false
    }

    struct MuteOutcome {
        var applied: Bool
        var savedVolumes: [String: Double]
        var mutedDevices: [String]
    }

    final class Queue {
        var jobs: [() -> Void] = []
        func async(execute action: @escaping () -> Void) { jobs.append(action) }
        func drain() { while !jobs.isEmpty { jobs.removeFirst()() } }
    }
    enum DispatchQueue {
        static let main = Queue()
    }

    static var devices: [Device] = []
    static var writes: [(uid: String, muted: Bool)] = []
    /// A device whose write is refused, standing in for a headset that is
    /// halfway through reconnecting.
    static var refusing: String?

    static func reset(_ starting: [Device]) {
        devices = starting
        writes = []
        refusing = nil
        DispatchQueue.main.jobs = []
    }

    static func device(_ uid: String) -> Device? { devices.first { $0.uid == uid } }
}

enum MicMuteStrandedTests {
    private typealias Context = MicMuteStrandedContract

    private static func silenced(_ uid: String, id: Int) -> Context.Device {
        Context.Device(id: id, uid: uid, muteSwitch: 1)
    }
    private static func open(_ uid: String, id: Int) -> Context.Device {
        Context.Device(id: id, uid: uid, muteSwitch: 0)
    }

    /// Runs both queues to quiescence, the way two live queues behave: the
    /// hardware sweep hands work back to the main thread, which can ask for
    /// another sweep. The bound only stops a runaway from hanging the suite.
    private static func settle(_ service: Context.Service) {
        for _ in 0..<10 where !service.halQueue.jobs.isEmpty || !Context.DispatchQueue.main.jobs.isEmpty {
            service.halQueue.drain()
            Context.DispatchQueue.main.drain()
        }
    }

    static func run(expect: (Bool, String) -> Void) {
        // MARK: the sweep that started it (issue #1568)

        // Every microphone already quiet, none of them this app's: the sweep
        // has silenced nothing, so it must not report a mute. Reporting one
        // is what wrote an active mute with an empty claim list, which the
        // unmute then had nothing to act on, leaving the microphone silent
        // with every record saying otherwise.
        Context.reset([silenced("built-in", id: 1)])
        let nothingToDo = Context.Service.mute([Context.devices[0]],
                                               savedVolumes: [:], mutedDevices: [])
        expect(!nothingToDo.applied && nothingToDo.mutedDevices.isEmpty,
               "a sweep that silenced nothing reports no mute, so none is recorded")

        // The precondition of the loop cannot be reached: an active mute now
        // always carries at least one device it can give back.
        Context.reset([silenced("built-in", id: 1), open("headset", id: 2)])
        let partly = Context.Service.mute(Context.devices, savedVolumes: [:], mutedDevices: [])
        expect(partly.applied && partly.mutedDevices == ["headset"],
               "a mute that reached one microphone claims that one and no other")
        expect(Context.device("built-in")?.muteSwitch == 1,
               "the microphone the person silenced themselves is not touched")

        // A device still muted from an earlier run stays this app's to release.
        Context.reset([silenced("built-in", id: 1)])
        let reasserted = Context.Service.mute(Context.devices, savedVolumes: [:],
                                              mutedDevices: ["built-in"])
        expect(reasserted.applied && reasserted.mutedDevices == ["built-in"],
               "a mute this app already holds is re-asserted and kept")

        // The ordinary case is unchanged.
        Context.reset([open("built-in", id: 1)])
        let plain = Context.Service.mute(Context.devices, savedVolumes: [:], mutedDevices: [])
        expect(plain.applied && plain.mutedDevices == ["built-in"]
                && Context.device("built-in")?.muteSwitch == 1,
               "an open microphone is silenced and claimed")

        // A driver that takes the write and keeps its level is never claimed.
        Context.reset([Context.Device(id: 4, uid: "interface", muteSwitch: nil,
                                      volume: 0.7, ignoresWrites: true)])
        let stubborn = Context.Service.mute(Context.devices, savedVolumes: [:], mutedDevices: [])
        expect(!stubborn.applied && stubborn.mutedDevices.isEmpty
                && stubborn.savedVolumes.isEmpty,
               "a device that keeps its level is not recorded as muted, and its level is not saved")

        // MARK: the way out when a mute is left behind

        // Nothing silent: nothing to offer.
        Context.reset([open("built-in", id: 1), open("headset", id: 2)])
        let quiet = Context.Service()
        quiet.refreshStrandedMute()
        settle(quiet)
        expect(!quiet.hasStrandedMute && Context.writes.isEmpty,
               "a Mac with no silenced microphone is offered nothing")

        // The case people are already stuck in: a mute left behind by a
        // previous version, with no record of it anywhere.
        Context.reset([silenced("built-in", id: 1)])
        let stranded = Context.Service()
        stranded.refreshStrandedMute()
        settle(stranded)
        expect(stranded.hasStrandedMute,
               "a microphone silent while the app claims nothing is recognized with no history at all")
        expect(Context.writes.isEmpty,
               "noticing never opens anything: past use is not standing permission")

        stranded.releaseStrandedMute()
        settle(stranded)
        expect(Context.writes.map(\.uid) == ["built-in"] && Context.writes.allSatisfy { !$0.muted },
               "the offer, once accepted, opens the microphone")
        expect(!stranded.hasStrandedMute, "and the offer goes away once it has")

        // While the app's own mute is on, every microphone is silent by design.
        Context.reset([silenced("built-in", id: 1)])
        let muted = Context.Service()
        muted.hasStrandedMute = true
        muted.isMuted = true
        muted.refreshStrandedMute()
        expect(!muted.hasStrandedMute && muted.halQueue.jobs.isEmpty,
               "the app's own mute is never mistaken for a stranded one")

        // Issue #1568's own sequence: a call silences the microphone again
        // after a release, and the offer has to come back for it.
        Context.reset([silenced("built-in", id: 1)])
        let again = Context.Service()
        again.refreshStrandedMute()
        settle(again)
        again.releaseStrandedMute()
        settle(again)
        expect(!again.hasStrandedMute, "released once")
        Context.devices = [silenced("built-in", id: 1)]
        again.refreshStrandedMute()
        settle(again)
        expect(again.hasStrandedMute,
               "a microphone silenced again during the same run is offered again, not once per launch")

        // A device that refuses the write keeps the way out visible.
        Context.reset([silenced("interface", id: 3)])
        Context.refusing = "interface"
        let refused = Context.Service()
        refused.refreshStrandedMute()
        settle(refused)
        refused.releaseStrandedMute()
        settle(refused)
        expect(Context.writes.map(\.uid) == ["interface"] && refused.hasStrandedMute,
               "an attempt that failed leaves the offer standing instead of waiting for a restart")

        // A microphone that arrives silenced later is noticed on the next look.
        Context.reset([open("built-in", id: 1)])
        let arriving = Context.Service()
        arriving.refreshStrandedMute()
        settle(arriving)
        expect(!arriving.hasStrandedMute, "nothing to offer yet")
        Context.devices.append(silenced("headset", id: 2))
        arriving.refreshStrandedMute()
        settle(arriving)
        expect(arriving.hasStrandedMute,
               "a microphone reconnected while silent is offered without restarting the app")
        arriving.releaseStrandedMute()
        settle(arriving)
        expect(Context.writes.map(\.uid) == ["headset"],
               "only the silent device is touched, never one that is already open")
    }
}
