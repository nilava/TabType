import Darwin
import Foundation

/// The same host identity is used for rule entry, legacy rules and live URLs.
enum WebsiteRule {
    static func host(from input: String) -> String? {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty,
              !value.unicodeScalars.contains(where: {
                  CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0)
              }) else { return nil }
        let address: String
        if value.contains("://") { address = value }
        else if value.hasPrefix("//") { address = "https:" + value }
        else if !value.hasPrefix("["), value.filter({ $0 == ":" }).count > 1 {
            address = "https://[" + value + "]"
        } else { address = "https://" + value }
        guard let parts = URLComponents(string: address),
              ["http", "https"].contains(parts.scheme?.lowercased() ?? ""),
              parts.user == nil, parts.password == nil,
              parts.port.map({ (0...65535).contains($0) }) ?? true,
              var host = parts.url?.host?.lowercased() else { return nil }
        if host.hasPrefix("["), host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        host = host.trimmingCharacters(in: CharacterSet(charactersIn: "."))
        guard !host.isEmpty, !host.contains("*"), !host.contains("%"), !host.contains("\\") else { return nil }

        // Browsers normalize abbreviated, numeric and hexadecimal IPv4 URLs.
        // Matching their canonical form avoids a second spelling of one host.
        var ipv4 = in_addr()
        if inet_aton(host, &ipv4) == 1 {
            var output = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            guard inet_ntop(AF_INET, &ipv4, &output, socklen_t(output.count)) != nil else { return nil }
            return String(cString: output)
        }
        if host.contains(":") {
            var ipv6 = in6_addr()
            guard inet_pton(AF_INET6, host, &ipv6) == 1 else { return nil }
            var output = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
            guard inet_ntop(AF_INET6, &ipv6, &output, socklen_t(output.count)) != nil else { return nil }
            return String(cString: output)
        }
        guard !host.allSatisfy({ $0.isNumber || $0 == "." }),
              !host.contains("..") else { return nil }
        return host
    }

    static func matches(host: String, rule: String) -> Bool {
        guard let host = self.host(from: host), let rule = self.host(from: rule) else { return false }
        return host == rule || host.hasSuffix("." + rule)
    }
}
