import ClewCore
import Foundation
import Testing

@Suite struct QuickEntryTests {
    @Test func plainTextIsATitle() {
        let p = QuickEntry.parse("  Apply to   1 job ")
        #expect(p == .init(title: "Apply to 1 job", url: nil, isBareLink: false))
    }

    @Test func titleAndLinkInEitherOrder() {
        let a = QuickEntry.parse("ML course https://course.example/ml")
        let b = QuickEntry.parse("https://course.example/ml ML course")
        #expect(a.title == "ML course" && a.url?.absoluteString == "https://course.example/ml" && !a.isBareLink)
        #expect(b == a)
    }

    @Test func bareLinkGetsAReadableTitle() {
        let p = QuickEntry.parse("https://www.youtube.com/watch?v=abc\n")
        #expect(p.isBareLink)
        #expect(p.title == "youtube.com/watch?v=abc")
        #expect(QuickEntry.parse("https://example.com/").title == "example.com")
        let long = QuickEntry.parse("https://example.com/" + String(repeating: "a", count: 200))
        #expect(long.title.count == 80 && long.title.hasSuffix("…"))
    }

    @Test func nonWebSchemesAreJustText() {
        #expect(QuickEntry.parse("file:///etc/passwd").url == nil)
        #expect(QuickEntry.parse("javascript:alert(1)").url == nil)
        #expect(QuickEntry.parse("mailto:a@b.c").url == nil)
    }
}
