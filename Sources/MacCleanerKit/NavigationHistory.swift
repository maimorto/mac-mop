import Foundation

/// Back/forward history like Finder's or System Settings': visiting a new
/// place pushes the current one on the back stack and forgets the forward
/// stack; going back/forward moves one step and returns the new place.
public struct NavigationHistory<Element: Equatable>: Equatable {
    public private(set) var current: Element?
    public private(set) var backStack: [Element] = []
    public private(set) var forwardStack: [Element] = []
    /// Oldest entries are dropped beyond this many steps.
    public let limit: Int

    public init(current: Element? = nil, limit: Int = 50) {
        self.current = current
        self.limit = max(1, limit)
    }

    public var canGoBack: Bool { !backStack.isEmpty }
    public var canGoForward: Bool { !forwardStack.isEmpty }

    /// Records a newly visited place. Re-visiting the current place is a no-op.
    public mutating func visit(_ element: Element) {
        guard element != current else { return }
        if let current { backStack.append(current) }
        if backStack.count > limit { backStack.removeFirst(backStack.count - limit) }
        forwardStack.removeAll()
        current = element
    }

    @discardableResult
    public mutating func goBack() -> Element? {
        guard let previous = backStack.popLast() else { return nil }
        if let current { forwardStack.append(current) }
        current = previous
        return previous
    }

    @discardableResult
    public mutating func goForward() -> Element? {
        guard let next = forwardStack.popLast() else { return nil }
        if let current { backStack.append(current) }
        current = next
        return next
    }

    /// Drops the forward stack (a sub-page went back on its own, so "forward"
    /// at the page level would no longer mean the place the user came from).
    public mutating func clearForward() { forwardStack.removeAll() }
}

/// Decides what the window's Back/Forward buttons do: a page's own drill-down
/// (results → done, folder → subfolder) goes first, then the page history.
public enum NavigationRouting {
    /// `withinPage`: the visible page steps back inside itself; `history`:
    /// move to the previously visited page.
    public enum Step: Equatable { case withinPage, history, none }

    public static func back(pageCanGoBack: Bool, historyCanGoBack: Bool) -> Step {
        pageCanGoBack ? .withinPage : (historyCanGoBack ? .history : .none)
    }

    public static func forward(pageCanGoForward: Bool, historyCanGoForward: Bool) -> Step {
        pageCanGoForward ? .withinPage : (historyCanGoForward ? .history : .none)
    }
}
