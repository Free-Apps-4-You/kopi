import Foundation
import Testing
@testable import KopiCore

@Suite("Radial clipboard")
struct RadialTests {
    @Test func directionsAndCancellation() {
        #expect(RadialSelection.index(x: 0, y: 0, count: 8) == nil)
        #expect(RadialSelection.index(x: 47, y: 0, count: 8) == nil)
        for (index, point) in [(0, (0.0, 100.0)), (1, (100, 100)), (2, (100, 0)),
                               (3, (100, -100)), (4, (0, -100)), (5, (-100, -100)),
                               (6, (-100, 0)), (7, (-100, 100))] {
            #expect(RadialSelection.index(x: point.0, y: point.1, count: 8) == index)
        }
        #expect(RadialSelection.index(x: 100, y: 0, count: 4) == 1)
        #expect(RadialSelection.index(x: -100, y: 0, count: 4) == 3)
        #expect(RadialSelection.index(x: 0, y: 100, count: 0) == nil)
    }

    @Test func boundaryHysteresisAvoidsJitter() {
        func point(_ degrees: Double) -> (Double, Double) {
            let angle = degrees * Double.pi / 180
            return (sin(angle) * 150, cos(angle) * 150)
        }
        let nearEdge = point(24)
        #expect(RadialSelection.index(x: nearEdge.0, y: nearEdge.1, count: 8) == 1)
        #expect(RadialSelection.index(x: nearEdge.0, y: nearEdge.1, count: 8, previous: 0) == 0)
        let pastEdge = point(30)
        #expect(RadialSelection.index(x: pastEdge.0, y: pastEdge.1, count: 8, previous: 0) == 1)
        #expect(RadialSelection.index(x: 0, y: 83, count: 8, previous: 0) == nil)
        #expect(RadialSelection.index(x: 0, y: 150, count: 1, previous: 7) == 0)
    }

    @Test func pagesReachEveryCardWithoutDuplicates() async throws {
        let workspace = try TempWorkspace()
        for index in 0..<19 {
            _ = try await workspace.store.insert(textInsertion("Radial card \(index)", destination: .collection))
        }
        var ids = Set<ClipboardItemID>()
        for page in 0..<3 {
            let result = try await workspace.store.page(HistoryQuery(scope: .collection, page: HistoryPage(offset: page * 8, limit: 8)))
            #expect(result.totalCount == 19)
            #expect(result.items.count == (page == 2 ? 3 : 8))
            for item in result.items { #expect(ids.insert(item.id).inserted) }
        }
        #expect(ids.count == 19)
    }

    @Test func defaultsAndPersistence() throws {
        #expect(KopiSettings().radialEnabled)
        #expect(try JSONDecoder().decode(KopiSettings.self, from: Data("{}".utf8)).radialEnabled)
        var settings = KopiSettings()
        settings.radialEnabled = false
        settings.radialCopiesOnly = true
        let data = try JSONEncoder().encode(settings)
        #expect(try !JSONDecoder().decode(KopiSettings.self, from: data).radialEnabled)
        #expect(try JSONDecoder().decode(KopiSettings.self, from: data).radialCopiesOnly)
        #expect(try !JSONDecoder().decode(KopiSettings.self, from: Data("{}".utf8)).radialCopiesOnly)
    }
}

import Carbon.HIToolbox
@testable import Kopi

@Suite("Radial shortcut routing")
@MainActor
struct RadialShortcutTests {
    @Test func releaseAndIndependentShortcutHandlers() {
        let panel = GlobalHotKey(identifier: 1)
        let radial = GlobalHotKey(identifier: 2)
        let ringEvent = EventHotKeyID(signature: GlobalHotKey.signature, id: 2)
        #expect(!panel.hotKeyPressed(ringEvent))
        #expect(radial.hotKeyPressed(ringEvent))
        #expect(radial.hotKeyPressed(ringEvent, released: true))
        #expect(!radial.hotKeyPressed(EventHotKeyID(signature: GlobalHotKey.signature, id: 1)))
        #expect(Set(RadialTrigger.allCases.map(\.hotkey)).count == RadialTrigger.allCases.count)
        #expect(RadialTrigger.allCases.allSatisfy { $0.hotkey != HotkeyDefinition.default })
    }
}
