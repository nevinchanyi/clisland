import Foundation

/// Pulls runnable shell commands out of fenced code blocks in an agent reply.
public enum CommandExtractor {
    static let shellLangs: Set<String> = ["bash", "sh", "shell", "zsh", "console", "terminal", "shellsession", "fish"]

    public static func extract(from markdown: String, limit: Int = 12) -> [String] {
        var commands = [String]()
        var inBlock = false
        var lang = ""
        var fence = ""
        var block = [String]()

        for rawLine in markdown.components(separatedBy: "\n") {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            if !inBlock {
                if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                    fence = String(trimmed.prefix(3))
                    lang = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                        .split(separator: " ").first.map { String($0).lowercased() } ?? ""
                    inBlock = true
                    block = []
                }
            } else if trimmed.hasPrefix(fence) && trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "`~")).isEmpty {
                inBlock = false
                if shellLangs.contains(lang) {
                    commands += parseBlock(block, promptOnly: ["console", "shellsession", "terminal"].contains(lang))
                }
            } else {
                block.append(rawLine)
            }
        }
        return Array(commands.prefix(limit))
    }

    static func parseBlock(_ lines: [String], promptOnly: Bool) -> [String] {
        var out = [String]()
        var current = ""
        var heredocEnd: String?
        let hasPrompts = lines.contains { $0.trimmingCharacters(in: .whitespaces).hasPrefix("$ ") }

        for raw in lines {
            if let end = heredocEnd {
                current += "\n" + raw
                if raw.trimmingCharacters(in: .whitespaces) == end {
                    out.append(current); current = ""; heredocEnd = nil
                }
                continue
            }
            var line = raw.trimmingCharacters(in: .whitespaces)
            if current.isEmpty {
                if line.isEmpty || line.hasPrefix("#") { continue }
                if line.hasPrefix("$ ") || line.hasPrefix("% ") {
                    line = String(line.dropFirst(2))
                } else if (promptOnly || hasPrompts) {
                    continue
                }
            }
            if line.hasSuffix("\\") {
                current += (current.isEmpty ? "" : " ") + String(line.dropLast()).trimmingCharacters(in: .whitespaces)
                continue
            }
            current += (current.isEmpty ? "" : " ") + line
            if let end = heredocTerminator(current) {
                heredocEnd = end
                continue
            }
            out.append(current)
            current = ""
        }
        if !current.isEmpty { out.append(current) }
        return out
    }

    static func heredocTerminator(_ line: String) -> String? {
        guard let r = line.range(of: #"<<-?\s*['"]?([A-Za-z_][A-Za-z0-9_]*)['"]?"#, options: .regularExpression) else { return nil }
        let token = line[r].replacingOccurrences(of: #"<<-?\s*['"]?"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: "'", with: "").replacingOccurrences(of: "\"", with: "")
        return token.isEmpty ? nil : token
    }

    /// Plain-text summary of a markdown reply: first meaningful sentence, no code.
    public static func summary(of markdown: String, max: Int = 160) -> String {
        var inBlock = false
        for raw in markdown.components(separatedBy: "\n") {
            let t = raw.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("```") || t.hasPrefix("~~~") { inBlock.toggle(); continue }
            if inBlock || t.isEmpty || t.hasPrefix("|") || t.allSatisfy({ "-=*_".contains($0) }) { continue }
            var s = t
            for prefix in ["#### ", "### ", "## ", "# ", "- ", "* ", "> "] where s.hasPrefix(prefix) {
                s = String(s.dropFirst(prefix.count))
            }
            s = s.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "`", with: "")
            s = s.replacingOccurrences(of: #"\[([^\]]+)\]\([^)]+\)"#, with: "$1", options: .regularExpression)
            if !s.isEmpty { return s.clipped(max) }
        }
        return ""
    }
}
