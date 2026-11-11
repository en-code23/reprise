import Foundation

enum ProjectAssessor {
    private static let ignored: Set<String> = [".git", ".hg", ".svn", "node_modules", "vendor", ".venv", "venv", ".build", "build", "dist", "target", "bin", "obj", ".next", "Pods", "DerivedData", "coverage", ".codex", ".claude", ".grok"]
    private static let codeExtensions: Set<String> = ["swift", "m", "mm", "h", "cs", "fs", "go", "rs", "py", "rb", "php", "java", "kt", "scala", "ts", "tsx", "js", "jsx", "vue", "svelte", "html", "css", "scss", "sql", "graphql", "proto", "cpp", "c", "ex", "exs"]

    static func assess(directory: URL, now: Date = .now) -> ProjectAssessment {
        var result = ProjectAssessment(sourceFiles: 0, backendFiles: 0, interfaceFiles: 0, testFiles: 0, manifests: 0, earlyProject: false)
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey, .contentModificationDateKey]
        guard let files = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles]) else { return result }
        var entries = 0
        for case let file as URL in files {
            entries += 1
            if entries > 12_000 { result.truncated = true; break }
            let values = try? file.resourceValues(forKeys: keys)
            if values?.isSymbolicLink == true { files.skipDescendants(); continue }
            if values?.isDirectory == true {
                if ignored.contains(file.lastPathComponent) { files.skipDescendants() }
                continue
            }
            let name = file.lastPathComponent.lowercased()
            if ["package.json", "package.swift", "cargo.toml", "go.mod", "pyproject.toml", "gemfile", "pom.xml", "composer.json"].contains(name) || file.pathExtension == "csproj" { result.manifests += 1 }
            let ext = file.pathExtension.lowercased()
            guard codeExtensions.contains(ext) else { continue }
            let relative = String(file.path.dropFirst(directory.path.count)).lowercased()
            let components = relative.split(separator: "/").map(String.init)
            result.sourceFiles += 1
            let tests = components.contains { ["test", "tests", "__tests__", "spec", "specs"].contains($0) } || name.contains(".test.") || name.contains(".spec.") || name.hasSuffix("tests.swift")
            if tests { result.testFiles += 1; continue }
            let ui = ["tsx", "jsx", "vue", "svelte", "css", "scss", "html"].contains(ext) || components.contains { ["views", "components", "screens", "frontend", "ui"].contains($0) } || name.hasSuffix("view.swift")
            let backend = ["sql", "graphql", "proto", "go", "rs", "py", "rb", "php", "java", "kt", "cs"].contains(ext) || components.contains { ["backend", "server", "api", "services", "migrations", "database", "auth"].contains($0) }
            if ui { result.interfaceFiles += 1 }
            if backend && !ui { result.backendFiles += 1 }
            if let modified = values?.contentModificationDate, now.timeIntervalSince(modified) >= 0, now.timeIntervalSince(modified) < 3600 * 24 {
                if ui { result.recentInterfaceFiles += 1 }
                if backend && !ui { result.recentBackendFiles += 1 }
            }
        }
        // Use Git's own capped count, without running hooks, shell text, or repository code.
        let git = Process(); git.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        git.arguments = ["-C", directory.path, "rev-list", "--count", "--max-count=21", "HEAD"]
        let pipe = Pipe(); git.standardOutput = pipe; git.standardError = FileHandle.nullDevice
        if (try? git.run()) != nil {
            let timer = DispatchWorkItem { if git.isRunning { git.terminate() } }
            DispatchQueue.global().asyncAfter(deadline: .now() + 2, execute: timer)
            let data = pipe.fileHandleForReading.readDataToEndOfFile(); git.waitUntilExit(); timer.cancel()
            if git.terminationStatus == 0, let count = Int(String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)) {
                result.earlyProject = count <= 8
            } else { result.earlyProject = FileManager.default.fileExists(atPath: directory.appendingPathComponent(".git").path) || result.sourceFiles < 25 }
        } else { result.earlyProject = result.sourceFiles < 25 }
        return result
    }
}
