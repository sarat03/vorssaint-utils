// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import Foundation
import CoreGraphics

/// Production action and sizing methods for an app with no windows, run against
/// recording doubles. No Dock, panel, or real application is involved.
enum DockPreviewWindowlessTests {
    enum PreviewSizing {
        /// Stands in for the preview size setting: 0.75 small … 1.8 xlarge.
        static var scale: CGFloat = 1
    }

    /// The panel geometry the production sizing methods are compiled against.
    /// The three numbers are fixtures, so the checks below are written as
    /// relationships rather than as the constants themselves.
    enum Support {
        typealias PreviewSizing = DockPreviewWindowlessTests.PreviewSizing
        static let edgePadding: CGFloat = 8
        static let windowlessPanelWidth: CGFloat = 360
        static let windowlessPanelHeight: CGFloat = 52
    }

    final class App {
        var bundleURL: URL?
        var calls: [String] = []

        init(bundleURL: URL? = URL(fileURLWithPath: "/Applications/Example.app")) {
            self.bundleURL = bundleURL
        }

        func unhide() { calls.append("unhide") }
        func activate() { calls.append("activate") }
        func hide() { calls.append("hide") }
        func terminate() { calls.append("terminate") }
    }

    enum NSWorkspace {
        static let shared = Workspace()

        final class OpenConfiguration {
            var activates = false
        }
    }

    final class Workspace {
        var opened: [URL] = []
        var activatingOpens = 0

        func openApplication(at url: URL, configuration: NSWorkspace.OpenConfiguration) {
            opened.append(url)
            if configuration.activates { activatingOpens += 1 }
        }
    }

    final class Service {
        typealias NSRunningApplication = DockPreviewWindowlessTests.App
        typealias NSWorkspace = DockPreviewWindowlessTests.NSWorkspace

        var windowlessApp: App?
        /// Every panel teardown and every app action, in the order they ran.
        var order: [String] = []

        func endSession() {
            order.append("panel closed")
        }
    }

    static func run(_ expect: (Bool, String) -> Void) {
        let workspace = NSWorkspace.shared
        workspace.opened = []
        workspace.activatingOpens = 0

        let service = Service()
        let app = App()
        service.windowlessApp = app
        service.performWindowlessAction(.open)
        expect(service.order == ["panel closed"] && app.calls == ["unhide"],
               "opening an app with no windows closes the panel first, then reveals the app")
        expect(workspace.opened.count == 1 && workspace.activatingOpens == 1,
               "opening re-opens the app so it puts a window back, and brings it forward")

        let hidden = App()
        service.windowlessApp = hidden
        service.performWindowlessAction(.hide)
        expect(hidden.calls == ["hide"] && workspace.opened.count == 1,
               "hiding hides the app and opens nothing")

        let quit = App()
        service.windowlessApp = quit
        service.performWindowlessAction(.quit)
        expect(quit.calls == ["terminate"],
               "quitting asks the app to terminate, so unsaved work still gets its own dialog")

        let unbundled = App(bundleURL: nil)
        service.windowlessApp = unbundled
        service.performWindowlessAction(.open)
        expect(unbundled.calls == ["unhide", "activate"] && workspace.opened.count == 1,
               "an app with no bundle on disk is activated rather than silently doing nothing")

        service.windowlessApp = nil
        let before = service.order.count
        service.performWindowlessAction(.quit)
        expect(service.order.count == before,
               "a panel that is not showing a windowless app performs no action at all")

        expect(DockPreviewWindowlessAction.allCases.count == 3,
               "the panel offers exactly the three actions the Dock's own menu does")

        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let base = Support.windowlessPanelSize(screenVisibleFrame: screen, previewScale: 1)
        let large = Support.windowlessPanelSize(screenVisibleFrame: screen, previewScale: 1.8)
        expect(large.width == base.width * 1.8 && large.height == base.height * 1.8,
               "a larger preview size grows the action row with the rest of the panel")

        let small = Support.windowlessPanelSize(screenVisibleFrame: screen, previewScale: 0.75)
        expect(small == base,
               "a smaller preview size leaves the row alone, since its labels are fixed-size text that a smaller setting cannot shorten")

        let narrow = CGRect(x: 0, y: 0, width: 200, height: 40)
        let clamped = Support.windowlessPanelSize(screenVisibleFrame: narrow, previewScale: 1.8)
        expect(clamped.width == narrow.width - Support.edgePadding * 2
                   && clamped.height == narrow.height - Support.edgePadding * 2,
               "a screen too small for the grown row clamps it rather than running it off the edge")
    }
}
