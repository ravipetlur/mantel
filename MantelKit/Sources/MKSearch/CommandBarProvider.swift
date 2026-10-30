/// A source of things the command bar can find: icons, Mantel's own actions, and what later versions add.
///
/// The command bar asks every provider once, when it opens, and filters what they answered as the person types, so a provider can take
/// its time to answer but is never asked again until the next time the bar opens.
public protocol CommandBarProvider: Sendable {
    /// What the provider is called, for the log and Diagnostics.
    var name: String { get }
    /// Everything it can offer now, in the order it should be listed in when nothing has been typed.
    func candidates() async -> [SearchCandidate]
}
