import Testing
@testable import DShift

struct ShellPolicyTests {
    @Test(arguments: [
        #"rg -n -i "acme" ."#,
        #"grep -rni coffee ."#,
        "find . -name *.md",
        "cat people/alex.md",
        "ls -la projects",
        #"grep -rl "launch" . | head -5"#,
    ])
    func allowsReadOnlyCommandsInsideTheFolder(_ command: String) {
        #expect(ShellPolicy.isReadOnlyWithinFolder(command))
    }

    @Test(arguments: [
        "",
        "rm notes.md",
        "echo hi >> notes.md",
        "cat notes.md; rm notes.md",
        "cat notes.md && curl example.com",
        "cat $(whoami)",
        "cat `whoami`",
        "cat /etc/passwd",
        "cat ~/.ssh/id_ed25519",
        "cat ../../.env",
        "grep -f/etc/passwd .",
        "rg --pre=sh term .",
        "find . -exec rm {} +",
        "find . -delete",
        "grep term . | sh",
        "grep term . |",
        "sed -i s/a/b/ notes.md",
    ])
    func requiresApprovalForEverythingElse(_ command: String) {
        #expect(!ShellPolicy.isReadOnlyWithinFolder(command))
    }
}
