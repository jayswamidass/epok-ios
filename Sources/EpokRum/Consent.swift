/// Consent is runtime-only. Every new Rum instance starts denied, including after relaunch.
public enum Consent: String, Codable, Sendable {
    case denied
    case granted
}
