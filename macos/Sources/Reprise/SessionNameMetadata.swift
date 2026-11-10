import Foundation

enum SessionNameMetadata {
    static let maximumIndexBytes = 8 * 1024 * 1024
    static let maximumClaudeTailBytes = 256 * 1024

    static func codexNames(at file: URL) throws -> [String: String] {
        guard FileManager.default.fileExists(atPath: file.path) else { return [:] }
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        let size = try handle.seekToEnd()
        let start = size > maximumIndexBytes ? size - UInt64(maximumIndexBytes) : 0
        try handle.seek(toOffset: start)
        var data = try handle.read(upToCount: maximumIndexBytes) ?? Data()
        if start > 0 { data = droppingPartialLine(data) }
        return codexNames(in: data)
    }

    static func codexNames(in data: Data) -> [String: String] {
        var names: [String: String] = [:]
        for line in data.split(separator: 0x0A) {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  let id = object["id"] as? String, UUID(uuidString: id) != nil,
                  let title = object["thread_name"] as? String else { continue }
            // Codex appends renames; the last valid record for an ID wins.
            names[id.lowercased()] = SessionName.clean(title)
        }
        return names
    }

    static func claudeTitleTail(from handle: FileHandle) throws -> Data {
        let size = try handle.seekToEnd()
        guard size > 256 * 1024 else { return Data() }
        let start = max(UInt64(256 * 1024), size - UInt64(maximumClaudeTailBytes))
        try handle.seek(toOffset: start)
        let tail = droppingPartialLine(try handle.read(upToCount: maximumClaudeTailBytes) ?? Data())
        var titles = Data()
        for line in tail.split(separator: 0x0A) {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  let id = object["sessionId"] as? String, UUID(uuidString: id) != nil else { continue }
            let keys = ["type", "sessionId", "cwd", "entrypoint", "isSidechain", "agentId", "customTitle", "aiTitle"]
            var metadata = object.filter { keys.contains($0.key) }
            if let name = metadata["customTitle"] as? String { metadata["customTitle"] = SessionName.clean(name) }
            if let name = metadata["aiTitle"] as? String { metadata["aiTitle"] = SessionName.clean(name) }
            titles.append(0x0A)
            titles.append(try JSONSerialization.data(withJSONObject: metadata))
        }
        return titles
    }

    private static func droppingPartialLine(_ data: Data) -> Data {
        guard let newline = data.firstIndex(of: 0x0A) else { return Data() }
        return Data(data.suffix(from: data.index(after: newline)))
    }
}
