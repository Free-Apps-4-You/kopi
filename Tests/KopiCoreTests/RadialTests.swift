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
        #expect(RadialSelection.index(x: 0, y: 47, count: 8, previous: 0) == nil)
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

import SwiftUI

@Suite("Radial segment hit regions")
struct RadialSegmentTests {
    @Test func segmentsCoverTheRingWithoutOverlappingTheHub() {
        let rect = CGRect(x: 0, y: 0, width: 456, height: 456)
        for count in 1...8 {
            let paths = (0..<count).map { RadialSegment(index: $0, count: count).path(in: rect) }
            #expect(paths.allSatisfy { !$0.contains(CGPoint(x: 228, y: 228)) }, "count \(count)")
            #expect(paths.allSatisfy { !$0.contains(CGPoint(x: 0, y: 0)) })
            for degrees in stride(from: 0.314, to: 360.0, by: 7.0) {
                let angle = degrees * Double.pi / 180
                let point = CGPoint(x: 228 + sin(angle) * 158, y: 228 - cos(angle) * 158)
                #expect(paths.filter { $0.contains(point) }.count == 1)
            }
            for index in 0..<count {
                let angle = Double(index) * 2 * Double.pi / Double(count)
                let point = CGPoint(x: 228 + sin(angle) * 158, y: 228 - cos(angle) * 158)
                #expect(paths[index].contains(point))
            }
        }
    }
}


import CoreText

@Suite("Radial content fitting")
struct RadialContentTests {
    @Test func completeImagesFitEverySectorWithoutCrossingTheHub() {
        for count in 1...8 {
            for index in 0..<count {
                let layout = RadialContentLayout(index: index, count: count)
                for aspect in [0.2, 0.6, 1, 1.8, 4.5] {
                    let rect = layout.imageRect(aspectRatio: aspect)
                    #expect(rect.width > 15 && rect.height > 15)
                    #expect(abs(rect.width / rect.height - aspect) < 0.001)
                    #expect(layout.contains(rect))
                }
            }
        }
    }

    @Test func textFollowsTheWedgeAndKeepsLongLinesInsideIt() {
        let samples = ["A short thought", String(repeating: "A useful idea worth keeping. ", count: 30),
                       "https://example.com/" + String(repeating: "long-path-", count: 60),
                       String(repeating: "こんにちは 世界 👋🏽 ", count: 40)]
        for count in 1...8 {
            for index in 0..<count {
                let layout = RadialContentLayout(index: index, count: count)
                let rows = layout.textRows()
                #expect(!rows.isEmpty)
                #expect(rows.allSatisfy { layout.contains($0) })
                for sample in samples {
                    let lines = RadialTextFlow.lines(sample, layout: layout, color: .black)
                    #expect(!lines.isEmpty)
                    for line in lines {
                        #expect(layout.contains(line.rect))
                        #expect(line.width <= line.rect.width + 0.5)
                    }
                }
            }
        }
        // The eight-item side wedge can use materially more width than the old
        // fixed 94-point card, while the top wedge tapers toward the hub.
        let side = RadialContentLayout(index: 2, count: 8).textRows()
        #expect(side.map(\.width).max()! >= 120)
        let top = RadialContentLayout(index: 0, count: 8).textRows()
        #expect(Set(top.map(\.width)).count > 2)
    }
}
