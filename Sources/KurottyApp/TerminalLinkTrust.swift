import Foundation

/// Where a link record's target came from.
///
/// The distinction is the whole point of the trust tiers: a text-scanned target
/// *is* the text the user read, while an OSC 8 target was chosen by the program
/// independently of the text it printed underneath it.
enum TerminalLinkProvenance: Equatable {
    /// The target arrived in an OSC 8 payload. The program picked both the
    /// target and the visible label, so the two can disagree.
    case oscHyperlink
    /// The target was read off rendered text. The label is the target.
    case textScan
}

/// Decides whether a link may be followed on the user's gesture alone, or
/// whether its real target has to be shown first.
///
/// Nothing here grants an open. The tier can only ever *add* a confirmation:
/// `TerminalSecurityPolicy` still decides what may be opened at all, and a
/// scheme it refuses stays refused.
enum TerminalLinkTrust {
    enum UntrustedReason: Equatable {
        /// The target does not parse as a URL at all.
        case unparsableTarget
        /// Control characters, format characters, or a newline in the target.
        /// Those can hide or reorder what the confirmation would print.
        case unsafeCharacters
        /// A scheme outside the set whose destination a user can read and judge.
        case untrustedScheme
        /// `user:pass@host`. The part before the `@` is not the host, and it is
        /// the part a reader's eye lands on first.
        case embeddedUserinfo
        /// An OSC 8 link whose visible text is not its target.
        case displayTextMismatch
    }

    enum Tier: Equatable {
        case trusted
        case untrusted(UntrustedReason)

        var isTrusted: Bool {
            self == .trusted
        }
    }

    /// The target of one of these lands somewhere the user can inspect before
    /// anything happens — a browser, the Finder, a mail composer — and its text
    /// form says where. Everything else is shown before it is followed.
    static let plainlyReadableSchemes: Set<String> = ["http", "https", "file", "mailto"]

    /// Stands in for a redacted `user:pass` prefix. Deliberately not a
    /// plausible userinfo string.
    static let redactedUserinfoPlaceholder = "…"

    /// A target reduced to what may safely be printed in a confirmation.
    struct SafeTarget: Equatable {
        /// The host the target actually resolves to, `nil` when it has none.
        let host: String?
        /// Display only: control characters removed and any userinfo replaced,
        /// so `https://apple.com@evil.example/` can never be read as Apple.
        let displayURLString: String
        /// What is actually opened once the user agrees: control characters
        /// removed, everything else — userinfo included — intact, because
        /// dropping it would open a different address than the one authorized.
        let resolvedURLString: String

        var resolvedURL: URL? {
            URL(string: resolvedURLString)
        }
    }

    static func tier(
        urlString: String,
        displayText: String,
        provenance: TerminalLinkProvenance
    ) -> Tier {
        guard !containsUnsafeScalars(urlString) else {
            return .untrusted(.unsafeCharacters)
        }
        guard let components = URLComponents(string: urlString),
              let scheme = components.scheme?.lowercased(),
              !scheme.isEmpty
        else {
            return .untrusted(.unparsableTarget)
        }
        guard plainlyReadableSchemes.contains(scheme) else {
            return .untrusted(.untrustedScheme)
        }
        guard components.user == nil, components.password == nil else {
            return .untrusted(.embeddedUserinfo)
        }
        switch provenance {
        case .textScan:
            // The scanner built the target out of the text it is printed as, so
            // there is no second address to disagree with. Adding a prompt here
            // would only teach people to dismiss the sheet unread.
            return .trusted
        case .oscHyperlink:
            let visible = displayText.trimmingCharacters(in: .whitespacesAndNewlines)
            return visible == urlString ? .trusted : .untrusted(.displayTextMismatch)
        }
    }

    static func safeTarget(forURLString urlString: String) -> SafeTarget {
        let resolved = removingUnsafeScalars(urlString)
        return SafeTarget(
            host: URLComponents(string: resolved)?.host,
            displayURLString: redactingUserinfo(in: resolved),
            resolvedURLString: resolved
        )
    }

    private static func containsUnsafeScalars(_ value: String) -> Bool {
        value.unicodeScalars.contains(where: isUnsafeScalar)
    }

    private static func removingUnsafeScalars(_ value: String) -> String {
        String(String.UnicodeScalarView(value.unicodeScalars.filter { !isUnsafeScalar($0) }))
    }

    /// C0/C1 controls, newlines, and Unicode format characters such as the
    /// bidirectional overrides, all of which can make printed text read as a
    /// different address than the one that would open.
    private static func isUnsafeScalar(_ scalar: Unicode.Scalar) -> Bool {
        CharacterSet.controlCharacters.contains(scalar) || CharacterSet.newlines.contains(scalar)
    }

    /// Replaces the `user:pass` of a `user:pass@host` authority textually rather
    /// than through `URLComponents`, which would re-encode the rest of the URL
    /// and change the string the user is being asked to trust.
    private static func redactingUserinfo(in urlString: String) -> String {
        guard let authorityStart = urlString.range(of: "://")?.upperBound else {
            return urlString
        }
        let authorityEnd = urlString[authorityStart...]
            .firstIndex(where: { $0 == "/" || $0 == "?" || $0 == "#" })
            ?? urlString.endIndex
        let authority = urlString[authorityStart..<authorityEnd]
        guard let userinfoEnd = authority.lastIndex(of: "@") else {
            return urlString
        }
        let hostPart = authority[authority.index(after: userinfoEnd)...]
        return urlString[urlString.startIndex..<authorityStart]
            + redactedUserinfoPlaceholder
            + "@"
            + hostPart
            + urlString[authorityEnd...]
    }
}

/// The decision for a link the user just activated: what the security policy
/// allows, narrowed by what the link's provenance and target make trustworthy.
enum TerminalLinkActivation {
    struct Decision: Equatable {
        let outcome: TerminalSecurityPolicy.Decision
        let tier: TerminalLinkTrust.Tier
        let safeTarget: TerminalLinkTrust.SafeTarget
        /// The text the user read, for a confirmation that has to show both
        /// sides of a mismatch.
        let displayText: String

        var requiresConfirmation: Bool {
            outcome == .ask
        }

        var openURL: URL? {
            safeTarget.resolvedURL
        }
    }

    static func decision(
        urlString: String,
        displayText: String,
        provenance: TerminalLinkProvenance,
        policy: TerminalSecurityPolicy
    ) -> Decision {
        let tier = TerminalLinkTrust.tier(
            urlString: urlString,
            displayText: displayText,
            provenance: provenance
        )
        let safeTarget = TerminalLinkTrust.safeTarget(forURLString: urlString)
        guard let url = safeTarget.resolvedURL else {
            return Decision(
                outcome: .deny,
                tier: tier,
                safeTarget: safeTarget,
                displayText: displayText
            )
        }
        let policyDecision = policy.userActivatedLinkDecision(for: url)
        // The tier narrows, never widens: an untrusted link loses the silent
        // open the gesture would otherwise have earned, and a scheme the policy
        // refuses is not promoted to a question.
        let outcome: TerminalSecurityPolicy.Decision
        if tier.isTrusted {
            outcome = policyDecision
        } else {
            outcome = policyDecision == .deny ? .deny : .ask
        }
        return Decision(
            outcome: outcome,
            tier: tier,
            safeTarget: safeTarget,
            displayText: displayText
        )
    }

    static func decision(
        for link: TerminalLinkRange,
        policy: TerminalSecurityPolicy
    ) -> Decision {
        decision(
            urlString: link.urlString,
            displayText: link.displayText,
            provenance: link.provenance,
            policy: policy
        )
    }
}
