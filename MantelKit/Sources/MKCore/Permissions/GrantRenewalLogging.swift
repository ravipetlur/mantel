/// What `FileGrantStore` says in the log about renewing a bookmark that went stale.
///
/// macOS replaces its settings files whenever it writes them, which makes the bookmark of a granted file stale each time, and each
/// time it is made anew. That is routine, and said once for each grant for as long as Mantel runs; saying it every time filled the log.
/// A renewal that fails is not routine and is said every time, so that nothing is hidden by the first one having been logged. A grant
/// made anew, or removed, starts over: it is another grant.
struct GrantRenewalLogging: Sendable, Equatable {
    enum Outcome: Sendable, Equatable {
        case renewed
        case couldNotRenew
    }

    private var renewalsLogged: Set<FileGrantKind> = []

    /// Whether to say this outcome of renewing `kind`'s bookmark: a renewal the first time for the kind, a failure always.
    mutating func shouldLog(_ outcome: Outcome, for kind: FileGrantKind) -> Bool {
        switch outcome {
        case .couldNotRenew: true
        case .renewed: renewalsLogged.insert(kind).inserted
        }
    }

    /// The grant of `kind` was made anew or removed.
    mutating func startOver(_ kind: FileGrantKind) {
        renewalsLogged.remove(kind)
    }
}
