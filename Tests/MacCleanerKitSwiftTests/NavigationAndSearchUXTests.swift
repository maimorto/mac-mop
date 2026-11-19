import Foundation
import Testing
@testable import MacCleanerKit

@Suite("Navigation history (Back / Forward)")
struct NavigationHistoryUXTests {
    @Test func startsWithNothingToGoBackOrForward() {
        let h = NavigationHistory<String>(current: "home")
        #expect(!h.canGoBack)
        #expect(!h.canGoForward)
        #expect(h.current == "home")
    }

    @Test func backAndForwardWalkVisits() {
        var h = NavigationHistory<String>(current: "a")
        h.visit("b"); h.visit("c")
        #expect(h.goBack() == "b")
        #expect(h.goBack() == "a")
        #expect(h.goBack() == nil)
        #expect(h.current == "a")
        #expect(h.goForward() == "b")
        #expect(h.goForward() == "c")
        #expect(h.goForward() == nil)
    }

    @Test func visitingAfterGoingBackDropsForward() {
        var h = NavigationHistory<String>(current: "a")
        h.visit("b"); h.goBack()
        #expect(h.canGoForward)
        h.visit("x")
        #expect(!h.canGoForward)
        #expect(h.backStack == ["a"])
    }

    @Test func revisitingCurrentIsNoOp() {
        var h = NavigationHistory<String>(current: "a")
        h.visit("a")
        #expect(!h.canGoBack)
    }

    @Test func limitDropsOldest() {
        var h = NavigationHistory<Int>(current: 0, limit: 3)
        for i in 1...10 { h.visit(i) }
        #expect(h.backStack == [7, 8, 9])
    }

    @Test func routingPrefersThePagesOwnBack() {
        #expect(NavigationRouting.back(pageCanGoBack: true, historyCanGoBack: true) == .withinPage)
        #expect(NavigationRouting.back(pageCanGoBack: false, historyCanGoBack: true) == .history)
        #expect(NavigationRouting.back(pageCanGoBack: false, historyCanGoBack: false) == .none)
        #expect(NavigationRouting.forward(pageCanGoForward: false, historyCanGoForward: true) == .history)
    }
}

@Suite("Search matching")
struct SearchMatcherUXTests {
    @Test func caseAndAccentInsensitive() {
        #expect(SearchMatcher.matches(query: "DUPLICATI", fields: ["Duplicati"]))
        #expect(SearchMatcher.matches(query: "ecran", fields: ["Écran"]))
        #expect(SearchMatcher.matches(query: "cronologia", fields: ["Cronologia pulizia"]))
    }

    @Test func everyWordMustMatchSomeField() {
        #expect(SearchMatcher.matches(query: "cache browser", fields: ["Privacy", "browser", "cache", "cookie"]))
        #expect(!SearchMatcher.matches(query: "cache zzz", fields: ["Privacy", "cache"]))
    }

    @Test func shortWordsMatchOnlyWordStarts() {
        #expect(SearchMatcher.matches(query: "ca", fields: ["Cache utente"]))
        #expect(!SearchMatcher.matches(query: "ca", fields: ["Applications"]))
        #expect(SearchMatcher.matches(query: "cat", fields: ["Applications"]))
    }

    @Test func titleMatchesRankFirst() {
        let items = [("Privacy", ["cookie", "cache"]), ("Cache", [String]())]
        let ranked = SearchMatcher.ranked(items, query: "cache") { [$0.0] + $0.1 }
        #expect(ranked.map(\.0) == ["Cache", "Privacy"])
    }

    @Test func emptyQueryMatchesNothing() {
        #expect(!SearchMatcher.matches(query: "  ", fields: ["anything"]))
    }
}

@Suite("Scan result filtering and pruning")
struct ScanResultFilterUXTests {
    func item(_ path: String, dir: Bool = false) -> FileItem {
        let url = URL(fileURLWithPath: path, isDirectory: dir)
        return FileItem(url: url, name: url.lastPathComponent, size: 10, allocatedSize: 10, isDirectory: dir)
    }

    var results: [ScanResult] {
        [ScanResult(category: .userCaches, items: [item("/Users/u/Library/Caches/com.google.Chrome", dir: true),
                                                   item("/Users/u/Library/Caches/com.google.Chrome/a.db"),
                                                   item("/Users/u/Library/Caches/Spotify", dir: true)]),
         ScanResult(category: .userLogs, items: [item("/Users/u/Library/Logs/x.log")])]
    }

    @Test func filterKeepsMatchingItemsAndDropsEmptyCategories() {
        let filtered = results.filtered(matching: "chrome")
        #expect(filtered.count == 1)
        #expect(filtered[0].items.count == 2)
        #expect(results.filtered(matching: "").count == 2)
        #expect(results.filtered(matching: "spotify caches").first?.items.count == 1)
    }

    @Test func removingDropsRemovedItemsAndTheirDescendants() {
        let removed: Set<URL> = [URL(fileURLWithPath: "/Users/u/Library/Caches/com.google.Chrome/", isDirectory: true),
                                 URL(fileURLWithPath: "/Users/u/Library/Logs/x.log")]
        let left = results.removing(removed)
        #expect(left.count == 1)
        #expect(left[0].items.map(\.name) == ["Spotify"])
    }

    @Test func removingSiblingWithSharedPrefixKeepsItem() {
        let removed: Set<URL> = [URL(fileURLWithPath: "/Users/u/Library/Caches/com.google")]
        #expect(results.removing(removed).flatMap(\.items).count == 4)
    }
}
