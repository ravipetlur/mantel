import Foundation
import MKCore

/// A blob that is a property list: it is read whole, the place is changed in the value, and the whole is written again in the
/// format it had (binary stays binary, XML stays XML).
///
/// Writing a list again is not a promise that nothing else about its bytes changes (the order a writer puts a dictionary's keys in
/// is its own). A blob that is a keyed archive can't be held (`PlistValue` has no object references): it is refused, and
/// `BinaryPlistFlip` is the codec for it.
///
/// A path is followed as `PlistValue` follows it, `matchingPath` included (the one entry of a list in which a way to a string reaches
/// the app's ID, wherever macOS has put it; none, or two, is an error): the list is read whole, the entry's place is changed, and every
/// other entry is written again exactly as it was, in the order it was in.
public struct NestedPlistCodec: PlistBlobCodec {
    public init() {}

    public func value(at path: PlistKeyPath, in blob: Data) throws -> PlistValue? {
        try decode(blob).value.value(at: path)
    }

    /// `blob` with `value` at `path`. When the place already holds it (or a removal finds nothing to remove) the answer is the very
    /// bytes that came in, not a new writing of the same list: a list some other writer made would come out in another byte order, and
    /// a change that changes nothing would still replace it. A place that can't be taken is an error all the same.
    public func setting(_ value: PlistValue?, at path: PlistKeyPath, in blob: Data) throws -> Data {
        let (decoded, format) = try decode(blob)
        let updated = try decoded.setting(value, at: path)
        guard updated != decoded else { return blob }
        return try Self.encode(updated, as: format)
    }

    private func decode(_ blob: Data) throws -> (value: PlistValue, format: PropertyListSerialization.PropertyListFormat) {
        try Self.decode(blob)
    }

    private static func decode(_ blob: Data) throws -> (value: PlistValue, format: PropertyListSerialization.PropertyListFormat) {
        var format = PropertyListSerialization.PropertyListFormat.binary
        let object: Any
        do {
            object = try PropertyListSerialization.propertyList(from: blob, options: [], format: &format)
        } catch {
            throw PlistBlobCodecError.notAPropertyList
        }
        switch PlistValue.converting(object) {
        case .value(let value):
            return (value, format)
        case .tooLarge:
            throw PlistBlobCodecError.tooLarge
        case .unrepresentable:
            // Something in it isn't a value of Mantel's: an archive's references are the one thing a list can hold that it isn't.
            throw (try? PlistNode.parse(blob).archiveObjects) != nil ? PlistBlobCodecError.isAnArchive : PlistBlobCodecError.containsReferences
        }
    }

    private static func encode(_ value: PlistValue, as format: PropertyListSerialization.PropertyListFormat) throws -> Data {
        do {
            return try PropertyListSerialization.data(fromPropertyList: value.propertyList, format: format, options: 0)
        } catch {
            throw PlistBlobCodecError.notAPropertyList
        }
    }
}
