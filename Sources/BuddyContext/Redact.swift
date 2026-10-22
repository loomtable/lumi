import Foundation

/// Removes secrets from command lines and URLs before they enter the packet.
/// Values are replaced with `‹redacted›`; names stay, so Claude Code still sees the shape.
public enum Redact {
    public static let mask = "‹redacted›"
    /// In URLs, ASCII so it isn't percent-encoded.
    public static let urlMask = "REDACTED"

    /// Substrings that mark a flag, header or query parameter name as secret-bearing.
    static let sensitiveParts = ["token", "secret", "password", "passwd", "auth", "credential", "session",
                                 "cookie", "signature"]

    /// `name` is a flag (`--api-key`), `key=` name, header name or query parameter name.
    static func isSensitive(_ name: String) -> Bool {
        let n = name.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "-_"))
        // "key" only as the whole name or a suffix part (api-key, ssh_key), not "keyboard".
        if n == "key" || n == "apikey" || n.hasSuffix("-key") || n.hasSuffix("_key") { return true }
        return sensitiveParts.contains { n.contains($0) }
    }

    /// Redacts an argv (program name first).
    public static func arguments(_ args: [String]) -> [String] {
        var out: [String] = []
        var maskNext = false
        for (i, arg) in args.enumerated() {
            if maskNext {
                out.append(mask)
                maskNext = false
                continue
            }
            if i == 0 {
                out.append(arg)
                continue
            }
            // --name=value / name=value
            if let eq = arg.firstIndex(of: "="), isSensitive(String(arg[..<eq])) {
                out.append(String(arg[...eq]) + mask)
                continue
            }
            // --token value
            if arg.hasPrefix("-"), isSensitive(arg), !arg.contains("=") {
                out.append(arg)
                maskNext = true
                continue
            }
            // "Authorization: Bearer …" and other secret headers.
            if let colon = arg.firstIndex(of: ":"), isSensitive(String(arg[..<colon])) {
                out.append(String(arg[...colon]) + " " + mask)
                continue
            }
            // mysql -pPASSWORD (attached, not a number like -p8080).
            if arg.hasPrefix("-p"), arg.count > 2, !arg.dropFirst(2).allSatisfy(\.isNumber),
               ["mysql", "mariadb", "mysqldump"].contains(Processes.basename(args[0])) {
                out.append("-p" + mask)
                continue
            }
            out.append(looksRandom(arg) ? mask : arg)
        }
        return out
    }

    /// A long token of mixed letters and digits with no path or word structure, e.g. an API key.
    static func looksRandom(_ s: String) -> Bool {
        guard s.count >= 24, !s.contains("/"), !s.contains(" ") else { return false }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_+=."))
        guard s.unicodeScalars.allSatisfy(allowed.contains) else { return false }
        let letters = s.filter(\.isLetter).count, digits = s.filter(\.isNumber).count
        return letters >= 6 && digits >= 4
    }

    /// Drops userinfo and the fragment (OAuth puts tokens there) and masks sensitive query values.
    public static func url(_ string: String) -> String {
        guard var c = URLComponents(string: string) else { return string }
        c.user = nil
        c.password = nil
        c.fragment = nil
        c.queryItems = c.queryItems?.map { item in
            isSensitive(item.name) || (item.value.map(looksRandom) ?? false)
                ? URLQueryItem(name: item.name, value: urlMask) : item
        }
        return c.string ?? string
    }
}
