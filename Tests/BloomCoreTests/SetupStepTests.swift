import Testing
@testable import BloomCore

@Suite("SetupStep")
struct SetupStepTests {
    /// The run that prompted this: a Docker setup on a small server, many minutes into compiling
    /// PHP extensions, where the last line of the log was a compiler warning about `gd.c`.
    @Test func aBuildKitLineIsReadThroughItsStepHeader() {
        let log = """
        + docker compose -f .bloom/docker/compose.yml build agent
        #8 [agent 3/9] RUN apt-get update && apt-get install -y libpng-dev libzip-dev
        #8 DONE 40.1s
        #9 [agent 4/9] RUN docker-php-ext-install -j2 bcmath pcntl pdo_pgsql pgsql intl gd zip
        #9 41.2 /usr/src/php/ext/gd/gd.c: In function 'zif_imagecreate':
        #9 41.3 warning: unused variable 'result'
        """
        let step = SetupStep.read(log: log)
        #expect(step == SetupStep(.compilingPHPExtensions, isInsideDockerBuild: true))
        #expect(step?.title == "Compiling PHP extensions for the Docker image")
    }

    @Test func aBuildStepWithACommandNothingKnowsIsStillTheDockerBuild() {
        let log = "#5 [agent 1/9] FROM docker.io/library/php:8.3-fpm\n#5 12.0 resolve done\n"
        #expect(SetupStep.read(log: log)?.title == "Building the Docker image")
    }

    @Test func npmInsideTheImageSaysSo() {
        let log = "#12 [agent 7/9] RUN npm install -g @openai/codex\n#12 3.1 added 1 package in 3s\n"
        #expect(SetupStep.read(log: log)?.title == "Installing npm packages for the Docker image")
    }

    @Test func theClassicBuilderIsReadFromItsStepLine() {
        #expect(SetupStep.read(log: "Step 4/9 : RUN composer install --no-dev\n")
            == SetupStep(.installingComposerPackages, isInsideDockerBuild: true))
    }

    @Test func colourCodesDoNotHideAStepHeader() {
        let log = "\u{1B}[1m#9 [agent 5/9] RUN pecl install redis imagick\u{1B}[0m\n#9 80.2 checking for gcc... gcc\n"
        #expect(SetupStep.read(log: log) == SetupStep(.installingPECLExtensions, isInsideDockerBuild: true))
    }

    @Test func aComposeBuildCommandIsTheDockerBuild() {
        #expect(SetupStep.read(log: "+ docker compose -f .bloom/docker/compose.yml build agent\n")?.activity == .buildingDockerImage)
    }

    @Test(arguments: [
        ("Installing dependencies from lock file\nPackage operations: 90 installs\n  - Installing symfony/console (v7.1.0): Extracting archive", SetupStep.Activity.installingComposerPackages),
        ("npm ci\n\nadded 312 packages, and audited 313 packages in 9s", .installingJavaScriptPackages(manager: "npm")),
        ("> vite build\nbuilding for production...\n✓ 120 modules transformed.", .buildingFrontEndAssets),
        ("php artisan migrate --force\n   INFO  Running migrations.\n  2024_01_01_000000_create_users_table ... 12ms DONE", .migratingDatabase),
        ("bundle install\nFetching gem metadata from https://rubygems.org/", .installingRubyGems),
        ("   Compiling serde v1.0.200\n   Compiling tokio v1.37.0", .compilingRustCrates),
        (" agent Pulling fs layer\n agent Downloading [==>   ] 12MB/80MB", .pullingDockerImages),
        ("Container there-there-db-1  Started", .startingContainers),
        ("Preparing this worktree's submodules.\nCloning into 'vendor/theme'...", .preparingSubmodules),
    ])
    func wellKnownToolsAreRecognised(log: String, activity: SetupStep.Activity) {
        #expect(SetupStep.read(log: log)?.activity == activity)
    }

    /// A setup script is a sequence of tools, and the one running is the one that printed last.
    @Test func theNewestRecognisedLineWins() {
        let log = "composer install\nGenerating autoload files\nnpm ci\nadded 10 packages in 2s\n"
        #expect(SetupStep.read(log: log)?.activity == .installingJavaScriptPackages(manager: "npm"))
    }

    /// A C build prints lines beginning with "Compiling" that are not cargo, and guessing Rust for
    /// them would be exactly the wrong diagnosis this type exists to avoid.
    @Test func compilingAloneIsNotRust() {
        #expect(SetupStep.read(log: "Compiling ext/gd with various options\n") == nil)
    }

    @Test func nothingRecognisedIsNil() {
        #expect(SetupStep.read(log: "Hello\nworld\n") == nil)
        #expect(SetupStep.read(log: "") == nil)
    }

    /// A finished install from long ago must not be reported as what is happening now.
    @Test func onlyTheRecentWindowIsRead() {
        let noise = Array(repeating: "cc -O2 -c file.c", count: SetupStep.window + 10).joined(separator: "\n")
        #expect(SetupStep.read(log: "composer install\n" + noise) == nil)
    }
}
