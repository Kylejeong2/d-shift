import Testing
@testable import DShift

struct MemoryPathTests {
    private let root = "/tmp/dshift-memory-tests"

    @Test(arguments: ["me.md", "notes.md", "people/alex-chen.md", "projects/q3/launch.md", "./people/sam.md"])
    func acceptsMarkdownInsideTheFolder(_ path: String) throws {
        let resolved = try #require(MemoryPath.resolve(path, inRoot: root))
        #expect(resolved.hasPrefix(root + "/"))
    }

    @Test(arguments: ["", "/etc/passwd.md", "~/notes.md", "../escape.md", "people/../../escape.md", "notes.txt", "people/", "script.sh"])
    func rejectsEverythingElse(_ path: String) {
        #expect(MemoryPath.resolve(path, inRoot: root) == nil)
    }
}
