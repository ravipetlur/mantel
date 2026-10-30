extension InstallFlow {
    /// A check that was running failed. The failure is recorded and then the flow settles: back to the offer when one
    /// is standing (the release a failed install or cancel left, or the one on offer when the check began), otherwise
    /// to idle. So a check that fails, a background one most of all, never loses an offer and never leaves the flow in
    /// the failed state, which belongs to an install. The caller says the failure where it should be said.
    ///
    /// False, and nothing changes, when no check is running: a result arriving late.
    public mutating func settleAfterFailedCheck(_ failure: UpdateFailure) -> Bool {
        guard state == .checking, handle(.failure(failure)) else { return false }
        if release != nil, handle(.retry) { return true }
        return handle(.dismiss)
    }
}
