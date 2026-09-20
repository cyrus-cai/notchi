import Foundation

/// Local check that runs on every copy before Copy Sense looks at it, and before
/// anything is sent to the gateway's Jev route. A clip that matches is dropped:
/// no hint, no classification, no request.
///
/// It looks for credentials only — things that are dangerous in a note and
/// useless as one. Addresses, phone numbers and order numbers pass, because
/// those are what a person does want saved.
enum ClipPrivacy {
    /// True when the clip contains something that looks like a credential.
    static func containsSecret(_ text: String) -> Bool {
        let range = NSRange(text.startIndex..., in: text)
        if patterns.contains(where: { $0.firstMatch(in: text, range: range) != nil }) { return true }
        if containsCardNumber(text) { return true }
        return containsHighEntropyToken(text)
    }

    // MARK: - Patterns

    private static let patterns: [NSRegularExpression] = [
        // Private keys and certificates' key blocks.
        #"-----BEGIN [A-Z ]*PRIVATE KEY-----"#,
        // Vendor key prefixes with a long body.
        #"\b(sk|rk|pk)[-_](live|test|proj|ant|or)?[-_]?[A-Za-z0-9_\-]{16,}"#,
        #"\b(ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9]{30,}"#,
        #"\bgithub_pat_[A-Za-z0-9_]{30,}"#,
        #"\bglpat-[A-Za-z0-9_\-]{20,}"#,
        #"\bxox[abposr]-[A-Za-z0-9\-]{10,}"#,
        #"\b(AKIA|ASIA)[A-Z0-9]{16}\b"#,
        #"\bAIza[0-9A-Za-z_\-]{35}"#,
        #"\bhf_[A-Za-z0-9]{30,}"#,
        #"\bnpm_[A-Za-z0-9]{36}"#,
        #"\bpypi-[A-Za-z0-9_\-]{50,}"#,
        #"\bSG\.[A-Za-z0-9_\-]{20,}\.[A-Za-z0-9_\-]{20,}"#,
        #"\b(whsec|sb_secret|shpat|shpss)_[A-Za-z0-9_]{16,}"#,
        // JSON Web Tokens.
        #"\beyJ[A-Za-z0-9_\-]{10,}\.eyJ[A-Za-z0-9_\-]{10,}\.[A-Za-z0-9_\-]{10,}"#,
        // Credentials inside a URL or connection string: scheme://user:pass@host.
        #"[a-z][a-z0-9+.\-]*://[^\s:/@]+:[^\s/@]+@"#,
        // A labelled secret: "password: …", "api_key=…", "密码：…".
        #"(?i)(password|passwd|pwd|passcode|secret|api[_\- ]?key|access[_\- ]?token|auth[_\- ]?token|private[_\- ]?key|密码|口令|密钥|验证码)\s*[:=：]\s*\S{4,}"#,
    ].compactMap { try? NSRegularExpression(pattern: $0) }

    // MARK: - Card numbers

    /// 13–19 digits (spaces or dashes allowed between groups) that pass Luhn.
    private static let cardCandidate = try? NSRegularExpression(pattern: #"\b\d(?:[ \-]?\d){12,18}\b"#)

    private static func containsCardNumber(_ text: String) -> Bool {
        guard let regex = cardCandidate else { return false }
        let range = NSRange(text.startIndex..., in: text)
        for match in regex.matches(in: text, range: range) {
            guard let r = Range(match.range, in: text) else { continue }
            let digits = text[r].compactMap(\.wholeNumberValue)
            if (13...19).contains(digits.count), luhn(digits) { return true }
        }
        return false
    }

    private static func luhn(_ digits: [Int]) -> Bool {
        var sum = 0
        for (i, d) in digits.reversed().enumerated() {
            if i % 2 == 1 {
                let doubled = d * 2
                sum += doubled > 9 ? doubled - 9 : doubled
            } else {
                sum += d
            }
        }
        return sum % 10 == 0
    }

    // MARK: - Unlabelled tokens

    /// A run of 24+ token characters with upper case, lower case and digits
    /// mixed, and high character entropy. Catches keys with no known prefix and
    /// generated passwords. `/` and `.` are not token characters here, so paths,
    /// domains and most URLs split into short runs and pass.
    private static let tokenRun = try? NSRegularExpression(pattern: #"[A-Za-z0-9_\-+=]{24,}"#)

    private static func containsHighEntropyToken(_ text: String) -> Bool {
        guard let regex = tokenRun else { return false }
        let range = NSRange(text.startIndex..., in: text)
        for match in regex.matches(in: text, range: range) {
            guard let r = Range(match.range, in: text) else { continue }
            let run = text[r]
            let hasUpper = run.contains(where: \.isUppercase)
            let hasLower = run.contains(where: \.isLowercase)
            let hasDigit = run.contains(where: \.isNumber)
            guard hasUpper, hasLower, hasDigit else { continue }
            if entropyPerCharacter(run) >= 3.5 { return true }
        }
        return false
    }

    private static func entropyPerCharacter(_ run: Substring) -> Double {
        var counts: [Character: Int] = [:]
        for c in run { counts[c, default: 0] += 1 }
        let n = Double(run.count)
        return counts.values.reduce(0) { total, count in
            let p = Double(count) / n
            return total - p * log2(p)
        }
    }
}
