import Foundation
import Testing
@testable import KopiCore

@Suite("Notes bridge values")
struct NotesBridgeValueTests {
    @Test func missingOrUnexpectedTextThrowsInsteadOfTrapping() {
        for value: Any? in [nil, NSNull(), NSNumber(value: 1), NSObject()] {
            #expect(throws: NotesClientError.self) {
                try ScriptingBridgeFailureRecorder.requireString(value)
            }
        }
    }
    @Test func stringsBridgeWithoutLosingEmptyOrUnicodeContent() throws {
        for text in ["", "Account-ID", "Notes ✨"] {
            #expect(try ScriptingBridgeFailureRecorder.requireString(text as NSString) == text)
        }
    }
}
