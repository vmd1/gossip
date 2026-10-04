import Foundation
import os

// Diagnostics policy: informational logging exists only in Debug builds, so the app that ships does not write
// connection details, device names, network names or session ids to the system log. Failures worth a bug report go
// through `gossipError`, which is kept in every build.

/// Shadows `Foundation.NSLog` inside this module: Debug builds log as before, Release builds log nothing.
/// (The old `NSLog` calls were unconditional and persisted in the unified log.)
func NSLog(_ format: String, _ args: CVarArg...) {
    #if DEBUG
    withVaList(args) { NSLogv(format, $0) }
    #endif
}

private let errorLogger = Logger(subsystem: "dev.vmd1.gossip", category: "error")

/// A failure worth keeping in a bug report; logged in every build at error level. Pass only what is safe to
/// persist: error descriptions and ids, never secrets, message contents or network names.
func gossipError(_ message: String) {
    errorLogger.error("\(redactAddresses(message), privacy: .public)")
}

private let addressPattern = try! NSRegularExpression(pattern: #"(?:\b\d{1,3}(?:\.\d{1,3}){3}\b)|(?:\b(?:[0-9a-fA-F]{1,4}:){7}[0-9a-fA-F]{1,4}\b)|(?:[0-9a-fA-F:]*::[0-9a-fA-F:.]*(?:%[A-Za-z0-9]+)?)"#)

/// Replaces IP addresses (error descriptions often embed the peer's) with `<address>` before a message is persisted.
func redactAddresses(_ message: String) -> String {
    addressPattern.stringByReplacingMatches(in: message, range: NSRange(message.startIndex..., in: message), withTemplate: "<address>")
}
