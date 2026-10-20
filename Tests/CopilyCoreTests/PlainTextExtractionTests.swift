import Foundation
import Testing

@testable import CopilyCore

@Suite("Rich text extraction")
struct PlainTextExtractionTests {
    @Test("HTML blocks become lines and entities are decoded")
    func htmlBlocks() {
        let html = "<p>Tea&nbsp;&amp; biscuits</p><p>Second<br>line</p>"

        #expect(PlainTextExtraction.plainText(fromHTML: html) == "Tea & biscuits\nSecond\nline")
    }

    @Test("HTML markup that is not text is dropped")
    func htmlNonTextContent() {
        let html = """
        <html><head><style>p { color: red }</style><script>alert("hi")</script></head>\
        <body><h1>Heading</h1><div>Body &quot;quoted&quot;</div><!-- <p>comment</p> --></body></html>
        """

        #expect(PlainTextExtraction.plainText(fromHTML: html) == "Heading\nBody \"quoted\"")
    }

    @Test("RTF keeps the label of a hyperlink and its escapes")
    func rtfFieldsAndEscapes() {
        let rtf = Data(#"""
        {\rtf1\ansi\deff0{\fonttbl{\f0 Helvetica;}}\f0\fs24 caf\'e9\par
        {\field{\*\fldinst{HYPERLINK "https://example.com/copily"}}{\fldrslt{\ul example.com}}}\par
        \u8212? done}
        """#.utf8)

        #expect(PlainTextExtraction.plainText(fromRTF: rtf) == "café\nexample.com\n\u{2014} done")
    }

    @Test("RTF that is not a document yields no text")
    func rtfWithoutDocument() {
        #expect(PlainTextExtraction.plainText(fromRTF: Data()) == "")
        #expect(PlainTextExtraction.plainText(fromHTML: "") == "")
    }

    @Test("RTF keeps characters outside the basic plane")
    func rtfCharactersOutsideBasicPlane() {
        #expect(PlainTextExtraction.plainText(fromRTF: rtfData("Plan \u{1F600} ready")) == "Plan \u{1F600} ready")
    }

    @Test("Excluded applications match bundle identifiers, case-insensitively")
    func excludedApplications() {
        let excluded = ExcludedApplications(bundleIdentifiers: ["com.apple.Passwords"])

        #expect(excluded.excludes(SourceAppInfo(bundleIdentifier: "COM.APPLE.PASSWORDS", name: "Passwords")))
        #expect(excluded.excludes(SourceAppInfo(bundleIdentifier: "com.apple.Passwords")) == true)
        #expect(excluded.excludes(SourceAppInfo(bundleIdentifier: "com.apple.Safari", name: "Safari")) == false)
        #expect(excluded.excludes(SourceAppInfo(name: "Unknown")) == false)
        #expect(excluded.excludes(nil) == false)
        #expect(ExcludedApplications().isEmpty)

        var editable = ExcludedApplications()
        editable.exclude("com.agilebits.onepassword7")
        #expect(editable.excludes(SourceAppInfo(bundleIdentifier: "com.agilebits.onepassword7")))
        editable.include("com.agilebits.onepassword7")
        #expect(editable.isEmpty)
    }
}
