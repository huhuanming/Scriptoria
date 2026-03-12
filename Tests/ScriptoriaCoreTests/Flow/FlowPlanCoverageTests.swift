import Foundation
import Testing

@Suite("Flow Plan Coverage", .serialized)
struct FlowPlanCoverageTests {
    @Test("all TC ids in plan should be present in tests")
    func testAllPlanTCIDsAreCovered() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Flow
            .deletingLastPathComponent() // ScriptoriaCoreTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // repo root

        let planURL = root.appendingPathComponent("docs/flow-dsl-architecture-plan.md")
        let testsRoot = root.appendingPathComponent("Tests")

        let planText = try String(contentsOf: planURL, encoding: .utf8)
        let planTCIDs = extractTCIDs(from: planText)

        let testFiles = try allSwiftFiles(in: testsRoot)
        var testTCIDs: Set<String> = []
        for fileURL in testFiles {
            let text = try String(contentsOf: fileURL, encoding: .utf8)
            testTCIDs.formUnion(extractTCIDs(from: text))
        }

        let missing = planTCIDs.subtracting(testTCIDs).sorted()
        #expect(
            missing.isEmpty,
            "Missing TC ids: \(missing.joined(separator: ", "))"
        )
    }

    private func extractTCIDs(from text: String) -> Set<String> {
        let pattern = "TC-[A-Z]+[0-9]{2}"
        let regex = try? NSRegularExpression(pattern: pattern)
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        let matches = regex?.matches(in: text, options: [], range: range) ?? []

        var ids: Set<String> = []
        for match in matches {
            guard let r = Range(match.range, in: text) else { continue }
            ids.insert(String(text[r]))
        }
        return ids
    }

    private func allSwiftFiles(in root: URL) throws -> [URL] {
        let keys: [URLResourceKey] = [.isDirectoryKey]
        let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: keys
        )
        var files: [URL] = []
        while let url = enumerator?.nextObject() as? URL {
            guard url.pathExtension == "swift" else { continue }
            files.append(url)
        }
        return files
    }
}
