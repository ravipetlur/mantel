/// The size a download is held to: the size the release lists for the file. One that goes past it is stopped at once, as a
/// size mismatch, and not downloaded to the end.
public enum DownloadSize {
    /// Whether `received` bytes are more than the release lists.
    public static func exceeds(listed: Int, received: Int64) -> Bool {
        received > Int64(listed)
    }

    /// Whether the server announced more than the release lists. An unknown length (zero or negative, as URLSession
    /// reports it) announces nothing.
    public static func exceeds(listed: Int, announced: Int64) -> Bool {
        announced > 0 && announced > Int64(listed)
    }
}
