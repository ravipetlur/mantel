import Foundation
import MKCore

/// How a path is followed into a value that is kept as a blob of bytes inside a plist key (a property list, or an archive of
/// one, stored as data): the paths of a journal entry and of a `PathEdit` are paths inside the blob, and the codec is what reads
/// and changes the blob at one.
///
/// A codec is registered with `PlistFileAccess` under a `PlistBlobCodecID`; an entry that names a codec that isn't registered
/// can't be read or put back (`PlistAccessError.codecMissing`).
public protocol PlistBlobCodec: Sendable {
    /// The value at `path` inside `blob`; nil when it isn't there.
    func value(at path: PlistKeyPath, in blob: Data) throws -> PlistValue?
    /// `blob` with `value` at `path` (nil removes what is there), the rest of it as it was. Throws `KeyPathError` when a step of
    /// the path can't be taken.
    func setting(_ value: PlistValue?, at path: PlistKeyPath, in blob: Data) throws -> Data
}

/// One change to one place inside a top-level key.
public struct PathEdit: Sendable, Equatable {
    public let path: PlistKeyPath
    /// What the place is to hold; nil removes it.
    public let value: PlistValue?

    public init(path: PlistKeyPath, value: PlistValue?) {
        self.path = path
        self.value = value
    }
}

/// The codecs the app registers with `PlistFileAccess`, by the IDs a journal entry names them by: `nested` (a blob that is a
/// property list, read and written whole), `flip` (a true or false changed in place in a binary property list or a keyed archive) and
/// `approvals` (the nested one, for the "Allow in the Menu Bar" list: `ApprovalsCodec`).
public enum PlistBlobCodecs {
    public static let nested = PlistBlobCodecID(rawValue: "nested")
    public static let flip = PlistBlobCodecID(rawValue: "flip")

    public static let standard: [PlistBlobCodecID: any PlistBlobCodec] = [
        nested: NestedPlistCodec(), flip: BinaryPlistFlip(), ApprovalsCodec.id: ApprovalsCodec(),
    ]
}
