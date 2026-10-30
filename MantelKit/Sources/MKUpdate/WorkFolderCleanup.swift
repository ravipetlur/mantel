/// The cleanup of an install's work folder, one decision at a time. The disk image mounted inside it is ejected once, and
/// the folder is removed only when nothing is mounted in it: removing a folder with a volume mounted in it would reach
/// into the volume. When the detach step already tried to eject, the cleanup doesn't try again (a stuck eject costs one
/// attempt, not two) and keeps the folder.
public enum WorkFolderCleanup {
    public enum Step: Equatable, Sendable {
        /// Eject the image, then ask again.
        case eject
        /// Nothing is mounted: remove the folder.
        case remove
        /// The image is mounted and the eject was tried: leave the folder, and say so in the log.
        case keep
    }

    /// The next step, given whether an eject has been tried and whether the image is still mounted.
    public static func next(ejectTried: Bool, mounted: Bool) -> Step {
        guard mounted else { return .remove }
        return ejectTried ? .keep : .eject
    }
}
