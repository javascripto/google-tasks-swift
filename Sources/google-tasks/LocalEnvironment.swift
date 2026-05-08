import Foundation

enum LocalEnvironment {
    static func value(for key: String) -> String {
        if let value = ProcessInfo.processInfo.environment[key], !value.isEmpty {
            return value
        }
        return envFileValues()[key] ?? ""
    }

    private static func envFileValues() -> [String: String] {
        let candidates = candidateEnvURLs()

        guard let url = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }) else {
            return [:]
        }
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            return [:]
        }

        return text.split(whereSeparator: \.isNewline).reduce(into: [:]) { values, line in
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#"), let separator = trimmed.firstIndex(of: "=") else {
                return
            }
            let key = trimmed[..<separator].trimmingCharacters(in: .whitespacesAndNewlines)
            let rawValue = trimmed[trimmed.index(after: separator)...].trimmingCharacters(in: .whitespacesAndNewlines)
            values[key] = rawValue.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        }
    }

    private static func candidateEnvURLs() -> [URL] {
        var candidates = [
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".env.local")
        ]

        var cursor = Bundle.main.bundleURL
        for _ in 0..<8 {
            candidates.append(cursor.appendingPathComponent(".env.local"))
            cursor.deleteLastPathComponent()
        }

        return candidates
    }
}
