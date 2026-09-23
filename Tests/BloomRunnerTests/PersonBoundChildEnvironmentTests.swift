import Testing
@testable import BloomRunner

/// What a person-bound launch hands the command it starts, after sudo has had its say.
@Suite("A sandboxed command's environment")
struct PersonBoundChildEnvironmentTests {
    @Test("the Runner's PATH survives sudo, so an agent still finds Bloom's git and gh")
    func pathSurvivesSudo() {
        let environment = PersonBoundSandboxExec.childEnvironment(from: [
            "PATH": "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/snap/bin",
            "BLOOM_PERSON_BOUND_PATH": "/var/lib/bloom/person-bound-shared/bin:/.sprite/bin:/usr/bin",
            "BLOOM_PERSON_BOUND_NONCE": "secret",
            "ANTHROPIC_BASE_URL": "http://127.0.0.1:4000",
        ])
        #expect(environment["PATH"] == "/var/lib/bloom/person-bound-shared/bin:/.sprite/bin:/usr/bin")
        #expect(environment["ANTHROPIC_BASE_URL"] == "http://127.0.0.1:4000")
        #expect(!environment.keys.contains { $0.hasPrefix("BLOOM_PERSON_BOUND_") })
    }

    @Test("with nothing carried, the PATH it was given stays")
    func nothingCarried() {
        let environment = PersonBoundSandboxExec.childEnvironment(from: ["PATH": "/usr/bin:/bin"])
        #expect(environment["PATH"] == "/usr/bin:/bin")
    }
}
