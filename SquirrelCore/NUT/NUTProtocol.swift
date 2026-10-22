import Foundation

/// Encoding and decoding for the NUT network protocol: ASCII, line oriented,
/// TCP 3493, multi-word values in double quotes with backslash escapes.
///
/// Reference: https://networkupstools.org/docs/developer-guide.chunked/net-protocol.html
public enum NUTProtocol {
    public static let defaultPort: UInt16 = 3493

    /// Splits a response line into tokens, honouring quoting and escapes.
    ///
    /// `VAR ups battery.charge "100"` becomes
    /// `["VAR", "ups", "battery.charge", "100"]`, and a quoted value keeps the
    /// spaces inside it rather than splitting on them.
    public static func tokenize(_ line: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var inQuotes = false
        var escaped = false
        var hasCurrent = false

        for character in line {
            if escaped {
                current.append(character)
                escaped = false
                continue
            }
            switch character {
            case "\\":
                escaped = true
                hasCurrent = true
            case "\"":
                inQuotes.toggle()
                hasCurrent = true
            case " ", "\t":
                if inQuotes {
                    current.append(character)
                } else if hasCurrent {
                    tokens.append(current)
                    current = ""
                    hasCurrent = false
                }
            default:
                current.append(character)
                hasCurrent = true
            }
        }
        if hasCurrent { tokens.append(current) }
        return tokens
    }

    /// Quotes a value for use as a command argument.
    public static func quote(_ value: String) -> String {
        var escaped = ""
        for character in value {
            if character == "\"" || character == "\\" { escaped.append("\\") }
            escaped.append(character)
        }
        return "\"\(escaped)\""
    }

    /// Builds a command line (without its trailing newline).
    public static func command(_ verb: String, _ arguments: [String] = [], quotingLast: Bool = false) -> String {
        var parts = [verb]
        for (index, argument) in arguments.enumerated() {
            let isLast = index == arguments.count - 1
            parts.append(quotingLast && isLast ? quote(argument) : argument)
        }
        return parts.joined(separator: " ")
    }
}

/// An `ERR <TOKEN>` reply from upsd, plus the transport-level failures a client
/// has to tell apart from them.
public enum NUTError: Error, Equatable, Sendable {
    case accessDenied
    case unknownUPS
    case variableNotSupported
    case commandNotSupported
    case invalidArgument
    case instantCommandFailed
    case setFailed
    case readOnly
    case tooLong
    case featureNotSupported
    case featureNotConfigured
    case alreadySSLMode
    case driverNotConnected
    case dataStale
    case alreadyLoggedIn
    case invalidPassword
    case alreadySetPassword
    case invalidUsername
    case alreadySetUsername
    case usernameRequired
    case passwordRequired
    case unknownCommand
    case invalidValue
    /// An `ERR` token upsd sent that this client does not know by name.
    case server(String)

    case notConnected
    case connectionFailed(String)
    case timedOut
    case malformedResponse(String)

    public init?(errorLine line: String) {
        let tokens = NUTProtocol.tokenize(line)
        guard tokens.first == "ERR", tokens.count >= 2 else { return nil }
        self = NUTError(token: tokens[1])
    }

    public init(token: String) {
        switch token {
        case "ACCESS-DENIED":          self = .accessDenied
        case "UNKNOWN-UPS":            self = .unknownUPS
        case "VAR-NOT-SUPPORTED":      self = .variableNotSupported
        case "CMD-NOT-SUPPORTED":      self = .commandNotSupported
        case "INVALID-ARGUMENT":       self = .invalidArgument
        case "INSTCMD-FAILED":         self = .instantCommandFailed
        case "SET-FAILED":             self = .setFailed
        case "READONLY":               self = .readOnly
        case "TOO-LONG":               self = .tooLong
        case "FEATURE-NOT-SUPPORTED":  self = .featureNotSupported
        case "FEATURE-NOT-CONFIGURED": self = .featureNotConfigured
        case "ALREADY-SSL-MODE":       self = .alreadySSLMode
        case "DRIVER-NOT-CONNECTED":   self = .driverNotConnected
        case "DATA-STALE":             self = .dataStale
        case "ALREADY-LOGGED-IN":      self = .alreadyLoggedIn
        case "INVALID-PASSWORD":       self = .invalidPassword
        case "ALREADY-SET-PASSWORD":   self = .alreadySetPassword
        case "INVALID-USERNAME":       self = .invalidUsername
        case "ALREADY-SET-USERNAME":   self = .alreadySetUsername
        case "USERNAME-REQUIRED":      self = .usernameRequired
        case "PASSWORD-REQUIRED":      self = .passwordRequired
        case "UNKNOWN-COMMAND":        self = .unknownCommand
        case "INVALID-VALUE":          self = .invalidValue
        default:                       self = .server(token)
        }
    }

    /// Whether the reading we already hold must stop being treated as the truth
    /// about the UPS. These are the cases that must never be published to
    /// `powerd` as a healthy power source.
    public var invalidatesReading: Bool {
        switch self {
        case .dataStale, .driverNotConnected, .unknownUPS, .notConnected,
             .connectionFailed, .timedOut:
            return true
        default:
            return false
        }
    }
}

/// A UPS as `LIST UPS` reports it.
public struct NUTDevice: Equatable, Sendable, Identifiable {
    public let name: String
    public let description: String

    public var id: String { name }

    public init(name: String, description: String) {
        self.name = name
        self.description = description
    }
}

public extension NUTError {
    /// A sentence to put in front of a person. The UI never shows the raw
    /// case, and the same wording is used wherever a NUT failure surfaces.
    var friendlyDescription: String {
        switch self {
        case .accessDenied:
            return "The NUT server rejected these credentials."
        case .unknownUPS:
            return "The server has no UPS by that name."
        case .dataStale:
            return "The server's data is stale; it has lost contact with the UPS."
        case .driverNotConnected:
            return "The server's UPS driver is not connected."
        case .usernameRequired, .passwordRequired:
            return "This server requires a username and password."
        case .invalidUsername, .invalidPassword:
            return "The username or password was not accepted."
        case .alreadySetUsername, .alreadySetPassword, .alreadyLoggedIn:
            return "The server is already handling another sign-in on this connection."
        case .commandNotSupported:
            return "This UPS does not support that command."
        case .instantCommandFailed:
            return "The server could not deliver that command to the UPS."
        case .variableNotSupported:
            return "This UPS does not report that value."
        case .featureNotSupported:
            return "The server asked for an encrypted connection, which Squirrel cannot provide yet."
        case .featureNotConfigured:
            return "The server has not been set up for that."
        case .alreadySSLMode:
            return "The connection is already encrypted."
        case .readOnly, .setFailed:
            return "The server would not accept that change."
        case .invalidArgument, .invalidValue, .tooLong:
            return "The server rejected one of the values Squirrel sent."
        case .unknownCommand:
            return "The server did not recognise that command."
        case .server(let token):
            return "The NUT server reported an error: \(token)."
        case .notConnected:
            return "Not connected."
        case .timedOut:
            return "The server did not respond."
        case .malformedResponse:
            return "The server answered, but not in the NUT protocol."
        case .connectionFailed(let detail):
            // The detail comes from the network stack, so it carries no
            // guarantee of being a finished sentence.
            let trimmed = detail.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return "Could not reach the server." }
            return "Could not reach the server: " + (trimmed.hasSuffix(".") ? trimmed : trimmed + ".")
        }
    }

    /// True when the problem is the credentials, so the UI can reopen the
    /// authentication fields rather than blaming the address.
    var isAuthenticationProblem: Bool {
        switch self {
        case .accessDenied, .usernameRequired, .passwordRequired,
             .invalidUsername, .invalidPassword:
            return true
        default:
            return false
        }
    }
}
