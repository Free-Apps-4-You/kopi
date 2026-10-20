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

@Suite("Radial focus redistribution")
struct RadialRedistributionTests {
    @Test func focusedArcGrowsWhileNeighborsKeepACompletePartition() {
        for count in 1...8 {
            for focused in 0..<count {
                let slices = RadialWheelLayout(count: count, focused: focused).slices
                let step = 2 * Double.pi / Double(count)
                #expect(abs(slices.reduce(0) { $0 + $1.sweep } - 2 * .pi) < 1e-10)
                #expect(abs(slices[focused].centerAngle - Double(focused) * step) < 1e-10)
                if count > 1 {
                    #expect(slices[focused].sweep > step)
                    #expect(slices.filter { $0.index != focused }.allSatisfy { $0.sweep < step && $0.sweep > 0 })
                }
                for pair in zip(slices, slices.dropFirst()) {
                    #expect(abs(pair.0.startAngle + pair.0.sweep - pair.1.startAngle) < 1e-10)
                }
            }
        }
    }

    @Test func animatedPartitionsNeverOverlapOrLeaveGaps() {
        let frame = CGRect(x: 0, y: 0, width: 440, height: 440)
        for count in 1...8 {
            // Include entering focus, moving clockwise, and wrapping 8 -> 1.
            for from in -1..<count {
                let to = (from + 1) % count
                for progress in [0.0, 0.2, 0.5, 0.8, 1] {
                    var weights = Array(repeating: 0.0, count: count)
                    if from >= 0 { weights[from] += 1 - progress }
                    weights[to] += progress
                    let slices = RadialWheelLayout(count: count, emphasis: weights).slices
                    let paths = slices.map { RadialSegment(slice: $0).path(in: frame) }
                    #expect(paths.allSatisfy { !$0.contains(CGPoint(x: 220, y: 220)) })
                    for degrees in stride(from: 0.731, to: 360.0, by: 11.0) {
                        let angle = degrees * Double.pi / 180
                        for radius in [55.0, 150, 210] {
                            let point = CGPoint(x: 220 + sin(angle) * radius, y: 220 - cos(angle) * radius)
                            #expect(paths.filter { $0.contains(point) }.count == 1, "count \(count), from \(from), progress \(progress), angle \(degrees)")
                        }
                    }
                }
            }
        }
    }

    @Test func hitTestingFollowsTheExpandedArcsAndRetainsTheCancelZone() {
        for count in 2...8 {
            for focused in 0..<count {
                let slices = RadialWheelLayout(count: count, focused: focused).slices
                for slice in slices {
                    #expect(RadialSelection.index(x: sin(slice.centerAngle) * 150, y: cos(slice.centerAngle) * 150,
                        count: count, previous: focused, magnified: true) == slice.index)
                }
                #expect(RadialSelection.index(x: 0, y: 47, count: count, previous: focused, magnified: true) == nil)
            }
        }
    }

    @Test func imagesAndMagnifiedTextStayInsideRedistributedSlices() {
        let frame = CGRect(x: 0, y: 0, width: 440, height: 440)
        let text = String(repeating: "A useful idea worth keeping. ", count: 12)
        for count in 1...8 {
            for focused in 0..<count {
                for slice in RadialWheelLayout(count: count, focused: focused).slices {
                    let layout = RadialContentLayout(slice: slice)
                    let path = RadialSegment(slice: slice).path(in: frame)
                    var rects = [0.4, 1, 2.4].map { layout.imageRect(aspectRatio: $0) }
                    let scale = slice.index == focused ? RadialGeometry.hoverScale : 1
                    let lines = RadialTextFlow.lines(text, layout: layout, color: .black, scale: scale)
                    #expect(!lines.isEmpty)
                    #expect(lines.allSatisfy { $0.width <= $0.rect.width + 0.5 })
                    rects += lines.map(\.rect)
                    for rect in rects {
                        #expect(rect.width > 0 && rect.height > 0)
                        for x in [rect.minX, rect.midX, rect.maxX] {
                            for y in [rect.minY, rect.midY, rect.maxY] {
                                #expect(path.contains(CGPoint(x: x, y: y)))
                            }
                        }
                    }
                }
            }
        }
    }
}
