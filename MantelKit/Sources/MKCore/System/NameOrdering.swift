import Foundation

/// How Settings and Diagnostics put apps in order, and how an app that has no name of its own is named.
public enum NameOrdering {
    /// `elements` in the order Finder would list their names: letters without regard to case or accents, and numbers by their value
    /// ("App 2" before "App 10"). Elements whose names are the same come in the order of their `tiebreak`, so the order never
    /// depends on the order they were given in.
    public static func sorted<Element>(_ elements: [Element], name: (Element) -> String, tiebreak: (Element) -> String) -> [Element] {
        elements.sorted { lhs, rhs in
            switch name(lhs).localizedStandardCompare(name(rhs)) {
            case .orderedAscending: true
            case .orderedDescending: false
            case .orderedSame: tiebreak(lhs) < tiebreak(rhs)
            }
        }
    }
}

/// The name Settings gives an app: what the running app calls itself, else the name of its bundle on disk, else its bundle ID.
public enum AppNames {
    /// The first of `runningName` and `bundleName` that isn't blank, or `bundleID` when both are.
    public static func resolve(bundleID: String, runningName: String?, bundleName: String?) -> String {
        for candidate in [runningName, bundleName] {
            if let name = candidate?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty { return name }
        }
        return bundleID
    }
}
