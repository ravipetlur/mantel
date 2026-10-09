import Foundation

/// What a settings file holds around the document: `{ "version": 2, "document": { … } }`.
struct Envelope<Document: Codable>: Codable {
    var version: Int
    var document: Document
}

/// Just the version, which can be read from a file whose document this version of Mantel can't read.
struct EnvelopeHeader: Decodable {
    var version: Int
}
