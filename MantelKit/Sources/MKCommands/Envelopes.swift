import Foundation

/// A command with the id its reply will carry.
public struct RequestEnvelope: Codable, Sendable, Equatable {
    public let id: UUID
    public let command: MantelCommand

    public init(id: UUID, command: MantelCommand) {
        self.id = id
        self.command = command
    }
}

/// What the app answers. `id` is the request's, or nil when the answer isn't to a request that could be read: a client
/// the app refused, or a line that wasn't a request.
public struct ReplyEnvelope: Codable, Sendable, Equatable {
    public let id: UUID?
    public let result: CommandResult

    public init(id: UUID?, result: CommandResult) {
        self.id = id
        self.result = result
    }
}
