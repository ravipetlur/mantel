/// What the OSStatus of a code-signature check says about the app.
public enum SignatureStatus {
    /// `errSecCSReqFailed`: the code is signed and its signature is valid, but it doesn't satisfy the requirement it was
    /// held to. For the running app's own designated requirement that means another signer: another team, or an ad-hoc
    /// signature, even one that claims this app's identifier.
    public static let requirementFailed: Int32 = -67050

    /// Why a check of the app's signature against this app's own designated requirement failed, or nil when it passed.
    /// A failed requirement is another signer; anything else (modified, unsigned, a resource missing or added, nested code
    /// unsigned) is a signature that isn't valid. One strict validation gives both answers.
    public static func failure(forStatus status: Int32) -> UpdateFailure? {
        switch status {
        case 0: nil
        case requirementFailed: .signerMismatch
        default: .signatureInvalid
        }
    }
}
