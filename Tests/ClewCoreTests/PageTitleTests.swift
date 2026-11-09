import Foundation
import ClewCore
import Testing

@Suite struct PageTitleTests {
    @Test func ogTitleWinsOverTheTitleTag() {
        // YouTube's shape: <title> carries a " - YouTube" suffix, og:title does not.
        let html = """
            <html><head><title>Never Gonna Give You Up - YouTube</title>
            <meta name="title" content="Never Gonna Give You Up">
            <meta property="og:title" content="Rick Astley - Never Gonna Give You Up">
            </head></html>
            """
        #expect(PageTitle.extract(fromHTML: html) == "Rick Astley - Never Gonna Give You Up")
    }

    @Test func attributeOrderQuotesAndCaseDoNotMatter() {
        let html = #"<META content='Attention Is All You Need' PROPERTY='og:title' />"#
        #expect(PageTitle.extract(fromHTML: html) == "Attention Is All You Need")
    }

    @Test func fallsBackThroughTwitterMetaNameAndTitleTag() {
        #expect(PageTitle.extract(fromHTML: #"<meta name="twitter:title" content="T"><title>X</title>"#) == "T")
        #expect(PageTitle.extract(fromHTML: #"<meta name="title" content="M"><title>X</title>"#) == "M")
        #expect(PageTitle.extract(fromHTML: "<title lang=\"en\">\n  [1706.03762] Attention\n</title>") == "[1706.03762] Attention")
        #expect(PageTitle.extract(fromHTML: #"<meta property="og:title" content="  "><title>Fallback</title>"#) == "Fallback")
    }

    @Test func entitiesAreDecoded() {
        let html = #"<meta property="og:title" content="Tom &amp; Jerry&#39;s &quot;best&quot; &#x2014; &lt;3 &bogus; & more">"#
        #expect(PageTitle.extract(fromHTML: html) == "Tom & Jerry's \"best\" — <3 &bogus; & more")
    }

    @Test func noTitleIsNil() {
        #expect(PageTitle.extract(fromHTML: "<html><body>hi</body></html>") == nil)
        #expect(PageTitle.extract(fromHTML: "") == nil)
    }
}

@Suite struct ReadEnoughTests {
    @Test func aStrayHeadEndIsNotEnoughButACompleteOgTitleIs() {
        // YouTube playlist shape: a "</head>" inside a script, then the real tags later.
        let early = Data(#"<script>var s = "</head>";</script>"#.utf8)
        #expect(!PageTitle.hasOpenGraphTitle(early))
        let partial = early + Data(#"<meta property="og:title" content="CS224N"#.utf8)
        #expect(!PageTitle.hasOpenGraphTitle(partial))
        #expect(PageTitle.hasOpenGraphTitle(partial + Data(#"">"#.utf8)))
    }
}
