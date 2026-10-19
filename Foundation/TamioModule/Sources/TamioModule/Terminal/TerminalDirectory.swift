//
//  TerminalDirectory.swift
//  TamioModule
//
//  The folder a server's terminal is in, so Files can open there. A shell
//  reports its folder with OSC 7 (ESC ] 7 ; file://host/path BEL) at each
//  prompt: some servers' shells do it by themselves, and Shell integration
//  in Edit Server › Advanced has the rest do it.
//

import Combine
import Foundation

/// The latest folder each server's terminals reported, whichever terminal
/// reported it: the one used last.
@MainActor
public final class TerminalDirectories: ObservableObject {
    public static let shared = TerminalDirectories()

    public struct Report: Equatable, Sendable {
        public let path: String
        /// Counts the reports, so a folder reported again after a move away
        /// is a change too.
        public let serial: Int
    }

    @Published public private(set) var latest: [RDMachine.ID: Report] = [:]
    private var serial = 0

    func report(_ path: String, for machine: RDMachine.ID) {
        guard latest[machine]?.path != path else { return }
        serial += 1
        latest[machine] = Report(path: path, serial: serial)
    }
}

/// Picks the folder a shell reports out of what it prints, across the
/// pieces the output arrives in.
struct WorkingDirectoryReader {
    private static let start = "\u{1B}]7;"
    /// Longer than any path a report would carry: past it, a report that
    /// never ended is given up.
    private static let limit = 4096
    private var pending = ""

    /// The folder last reported in `text`, if any.
    mutating func read(_ text: String) -> String? {
        let text = pending + text
        pending = ""
        var found: String?
        var rest = text[...]
        while let open = rest.range(of: Self.start) {
            let body = rest[open.upperBound...]
            // BEL ends it, or ESC \.
            guard let close = body.firstIndex(where: { $0 == "\u{07}" || $0 == "\u{1B}" }) else {
                if body.count < Self.limit { pending = String(rest[open.lowerBound...]) }
                return found
            }
            if let path = Self.path(in: String(body[..<close])) { found = path }
            rest = body[close...].dropFirst()
        }
        // The start of a report cut off at the end of this piece.
        if let escape = rest.lastIndex(of: "\u{1B}"), Self.start.hasPrefix(rest[escape...]) {
            pending = String(rest[escape...])
        }
        return found
    }

    /// The path in `file://host/path`; shells that encode it percent-encode
    /// it, and the hook Tamio types does not.
    static func path(in url: String) -> String? {
        guard let scheme = url.range(of: "://") else { return nil }
        let afterHost = url[scheme.upperBound...]
        guard let slash = afterHost.firstIndex(of: "/") else { return nil }
        let raw = String(afterHost[slash...])
        return raw.removingPercentEncoding ?? raw
    }
}

public enum ShellIntegration {
    /// Typed once the shell is open: has bash, zsh or fish report the folder
    /// at every prompt. It leads with a space, which keeps it out of the
    /// history where the shell is set to (bash's ignorespace, zsh's
    /// HIST_IGNORE_SPACE). It works only for the session it is typed in and
    /// writes nothing on the server.
    public static let hook = #" test -n "$FISH_VERSION" && eval 'function __tamio_cwd --on-event fish_prompt; printf "\e]7;file://%s\a" $PWD; end' || eval '__tamio_cwd() { printf "\033]7;file://%s\007" "$PWD"; }; if [ -n "$ZSH_VERSION" ]; then precmd_functions+=(__tamio_cwd); else PROMPT_COMMAND="__tamio_cwd${PROMPT_COMMAND:+;$PROMPT_COMMAND}"; fi'"#
}
