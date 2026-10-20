/// Inert by design: no credential parameter, transport, endpoint, or DELETE API.
/// A public ingest key cannot be passed to this boundary as deletion authority.
public enum SessionErasure {
    public enum Result: Equatable, Sendable {
        case deniedRequiresSessionScopedAuthorization
    }

    public static func request() -> Result { .deniedRequiresSessionScopedAuthorization }
    // Any future implementation needs an authenticated backend capability bound to
    // one tenant + session + delete action, with ownership, expiry and replay checks.
}
