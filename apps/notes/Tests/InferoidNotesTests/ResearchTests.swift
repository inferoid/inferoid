import XCTest
@testable import InferoidNotesKit

final class ResearchTests: XCTestCase {
    func testSearchBlockAndDeclineDetection() {
        XCTAssertEqual(Research.searchRequest(in: "```search\nThink Again Adam Grant\n```"), "Think Again Adam Grant")
        XCTAssertNil(Research.searchRequest(in: "Plain answer."))
        XCTAssertTrue(Research.declined("I only have the one excerpt: \u{201C}Amazing Book.\u{201D} I can't honestly summarize the book's main ideas."))
        XCTAssertTrue(Research.declined("That's not in your records."))
        XCTAssertFalse(Research.declined("Dana promised the proposal by Friday."))
    }

    func testParagraphsFollowStyleAndSourceIDsRoundTrip() {
        XCTAssertEqual(Research.paragraphs(style: "short and direct"), 1)
        XCTAssertEqual(Research.paragraphs(style: "more detail please"), 2)
        let page = ResearchPage(title: "Think Again (book)", url: URL(string: "https://en.wikipedia.org/wiki/Think_Again_(book)")!, text: "", engine: "Wikipedia")
        let parsed = ResearchPage.parse(sourceID: page.sourceID)
        XCTAssertEqual(parsed?.title, "Think Again (book)")
        XCTAssertEqual(parsed?.url, page.url)
        XCTAssertNil(ResearchPage.parse(sourceID: "/Users/x/Meetings/2026-11-17"))
    }

    @MainActor func testSearchFenceIsHiddenWhileStreaming() {
        XCTAssertEqual(ChatStore.visibleText("```search\nThink Again"), "")
    }

    func testExaHostedReplyParses() {
        let json = #"{"result":{"content":[{"type":"text","text":"Title: Six Great Ideas\nURL: https://quillette.com/2021/05/28/six/\nPublished: 2021-05-28\nAuthor: Jon Hersey\nHighlights:\nThink like a scientist.\n\n...\n\nAsk what would change your mind.\n\n---\n\nTitle: Local\nURL: http://127.0.0.1/x\nHighlights:\nno"}]}}"#
        let pages = ExaProvider.parseHosted("event: message\ndata: " + json + "\n")
        XCTAssertEqual(pages.count, 1)
        XCTAssertEqual(pages.first?.title, "Six Great Ideas")
        XCTAssertTrue(pages.first?.text.contains("scientist") == true)
        XCTAssertFalse(pages.first?.text.contains("...") == true)
    }

    func testDuckDuckGoResultsAndPageText() {
        let html = ##"<div><a rel="nofollow" class="result__a" href="//duckduckgo.com/l/?uddg=https%3A%2F%2Fexample.com%2Fbook&amp;rut=x">Think <b>Again</b></a><a class="result__snippet" href="#">A book about rethinking.</a></div>"##
        let hits = DuckDuckGoProvider.parse(html)
        XCTAssertEqual(hits.first?.1.absoluteString, "https://example.com/book")
        XCTAssertEqual(hits.first?.0, "Think Again")
        XCTAssertEqual(hits.first?.2, "A book about rethinking.")
        let page = PageReader.text(fromHTML: "<script>x()</script><h2>Ideas</h2><p>Think like a scientist and ask what evidence would change your mind.</p><p>short</p>")
        XCTAssertEqual(page, "Ideas\nThink like a scientist and ask what evidence would change your mind.")
    }

    func testOnlyPublicAddressesAreRead() {
        XCTAssertTrue(ResearchHTTP.isPublic(URL(string: "https://quillette.com/a")!))
        XCTAssertFalse(ResearchHTTP.isPublic(URL(string: "http://169.254.169.254/latest")!))
        XCTAssertFalse(ResearchHTTP.isPublic(URL(string: "http://192.168.1.5/admin")!))
        XCTAssertFalse(ResearchHTTP.isPublic(URL(string: "http://localhost:8080")!))
        XCTAssertFalse(ResearchHTTP.isPublic(URL(string: "file:///etc/passwd")!))
    }

    func testQueryNamesTheSavedBookAndHomePagesAreDropped() {
        let book = CollectionItem(kind: .library, title: "Think Again: The Power of Knowing What You Don't Know", creator: "Adam Grant")
        XCTAssertEqual(Research.enrich("book summary key ideas", question: "I read that book Think Again a while ago, remind me", items: [book]),
                       "Think Again Adam Grant book summary key ideas")
        XCTAssertEqual(Research.enrich("Think Again Adam Grant", question: "remind me about Think Again", items: [book]), "Think Again Adam Grant")
        XCTAssertTrue(Research.isHomePage(URL(string: "https://bookbrief.io/")!))
        XCTAssertFalse(Research.isHomePage(URL(string: "https://bookbrief.io/books/think-again-adam-grant")!))
    }

    func testCurlyApostropheRefusalTriggersSearch() {
        XCTAssertTrue(Research.declined("I can\u{2019}t honestly summarize the book from these pages. I won\u{2019}t invent its main ideas."))
        XCTAssertTrue(Research.citesWebWithoutSearch("Old answer [Web: Free Book Summaries]"))
    }

    func testQueryComesFromTheQuestionAndFollowUpsAreRecognised() {
        let book = CollectionItem(kind: .library, title: "Think Again: The Power of Knowing What You Don't Know", creator: "Adam Grant")
        let question = "I read that book Think Again a while ago, can you remind me the most important things about it?"
        XCTAssertEqual(Research.query(from: question), "book Think Again key ideas")
        XCTAssertEqual(Research.enrich(Research.query(from: question), question: question, items: [book]), "Adam Grant book Think Again key ideas")
        XCTAssertTrue(Research.isFollowUp("tell me more"))
        XCTAssertTrue(Research.isFollowUp("intresting, tell me some more"))
        XCTAssertFalse(Research.isFollowUp("What did Dana promise on Friday?"))
        XCTAssertTrue(Research.isCopiedBook(URL(string: "https://archive.org/stream/think-again/Think_djvu.txt")!))
        XCTAssertFalse(Research.isCopiedBook(URL(string: "https://www.goodreads.com/book/show/55539565-think-again")!))
    }

    func testCitationsAreRemovedFromTheShownText() {
        let raw = "Rethinking matters at every stage [Web: Key Insights], [Web: SparkNotes].\n\n[Web: Learning to unlearn]"
        XCTAssertEqual(MessageRow.withoutCitations(raw), "Rethinking matters at every stage.")
        XCTAssertEqual(MessageRow.withoutCitations("Dana owes the deck [Meeting: Q1 sync, 2026-11-14]."), "Dana owes the deck.")
    }

    func testOnlyWorldQuestionsAreSearched() {
        XCTAssertTrue(Research.wantsWorldFacts("I read that book Think Again a while ago, can you remind me the most important things about it?"))
        XCTAssertTrue(Research.wantsWorldFacts("Who wrote Think Again?"))
        XCTAssertFalse(Research.wantsWorldFacts("as you know he is a friend, do you think he is a good candidate to be first person to test?"))
        XCTAssertFalse(Research.wantsWorldFacts("ok, as you saw I been to hawaii, what are the other places like that I should visit?"))
        XCTAssertFalse(Research.wantsWorldFacts("Should I sell to businesses first?"))
    }
}
