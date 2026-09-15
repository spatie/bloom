import Foundation

/// What a running setup script is doing, in words, read out of the output it has printed so far.
///
/// The setup row used to say "Setting up" for the whole of a run and put the last line of the log
/// beside it. That is fine for a script that takes ten seconds and useless for the one that
/// prompted this: a Docker based setup on a two core server spent many minutes compiling PHP
/// extensions from source, and the last line was a C compiler warning about `gd.c`. The owner
/// could not tell a build that was working from one that had hung, and asked for a sentence
/// saying what the script was doing, with the log still one click away.
///
/// ## How the step is found
///
/// The newest line that a rule recognises wins, reading back through the last `window` lines.
/// Newest rather than first, because a setup script is a sequence of tools and the one that is
/// running is the one that printed last. The rules are the commands and banners the tools
/// themselves print, `composer install`, `added 312 packages`, `Pulling fs layer`, never words
/// that merely sound like progress, so a line the rules do not know is passed over rather than
/// guessed at, and a log nothing recognises gives nil. The caller falls back to the last line.
///
/// ## Docker builds
///
/// A BuildKit build prefixes every line of every step with its step number, `#9 41.2 ...`, so the
/// line that is running is almost never the command. The step's own header, `#9 [agent 4/9] RUN
/// docker-php-ext-install ...`, is further up, and it says what the build is doing far better than
/// "Building the Docker image" does. So a numbered line is traced back to its header, the header's
/// command is read with the same rules, and the answer says it is happening inside the image. The
/// classic builder's `Step 4/9 : RUN ...` is read the same way.
public struct SetupStep: Sendable, Hashable {
    public enum Activity: Sendable, Hashable {
        case compilingPHPExtensions
        case installingPECLExtensions
        case installingComposerPackages
        case installingJavaScriptPackages(manager: String)
        case buildingFrontEndAssets
        case migratingDatabase
        case seedingDatabase
        case installingRubyGems
        case installingPythonPackages
        case compilingRustCrates
        case downloadingGoModules
        case installingSystemPackages
        case buildingDockerImage
        case pullingDockerImages
        case startingContainers
        case preparingSubmodules
    }

    public let activity: Activity
    /// Whether the activity was read out of a Docker build step rather than run by the script
    /// directly. "Installing npm packages" and "installing npm packages for the Docker image" are
    /// different amounts of waiting, and the second one is not fixed by anything in the worktree.
    public let isInsideDockerBuild: Bool

    public init(_ activity: Activity, isInsideDockerBuild: Bool = false) {
        self.activity = activity
        self.isInsideDockerBuild = isInsideDockerBuild && activity != .buildingDockerImage
    }

    /// How many lines back from the end are read. A step banner is printed once and then
    /// followed by its tool's output, so this has to reach past a few hundred lines of compiler
    /// noise, and it must not reach so far that a finished `composer install` from ten minutes
    /// ago is reported as what is happening now. It is also asked from a view body, where the log
    /// can be two hundred thousand characters, which is why it is a tail and not the whole log.
    public static let window = 400

    public var title: String {
        let words = Self.words(activity)
        return isInsideDockerBuild ? words + " for the Docker image" : words
    }

    public static func read(log: String) -> SetupStep? {
        let lines = LogTail.last(log, lines: window)
            .split(omittingEmptySubsequences: true, whereSeparator: { $0 == "\n" || $0 == "\r" })
            .map { strippingEscapes(String($0)).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        for index in lines.indices.reversed() {
            let line = lines[index]
            if let step = dockerStep(line, before: lines[..<index]) { return step }
            if let activity = activity(line) { return SetupStep(activity) }
        }
        return nil
    }

    // MARK: Rules

    private static func words(_ activity: Activity) -> String {
        switch activity {
        case .compilingPHPExtensions: "Compiling PHP extensions"
        case .installingPECLExtensions: "Installing PHP extensions from PECL"
        case .installingComposerPackages: "Installing Composer packages"
        case .installingJavaScriptPackages(let manager): "Installing \(manager) packages"
        case .buildingFrontEndAssets: "Building front-end assets"
        case .migratingDatabase: "Running database migrations"
        case .seedingDatabase: "Seeding the database"
        case .installingRubyGems: "Installing Ruby gems"
        case .installingPythonPackages: "Installing Python packages"
        case .compilingRustCrates: "Compiling Rust crates"
        case .downloadingGoModules: "Downloading Go modules"
        case .installingSystemPackages: "Installing system packages"
        case .buildingDockerImage: "Building the Docker image"
        case .pullingDockerImages: "Pulling Docker images"
        case .startingContainers: "Starting containers"
        case .preparingSubmodules: "Preparing submodules"
        }
    }

    /// One line, read on its own. Ordered so the more particular rule is asked first: `npm run
    /// build` is a build and not an install, and `docker-php-ext-install` is PHP and not Docker.
    static func activity(_ line: String) -> Activity? {
        let text = line.lowercased()
        func has(_ words: String...) -> Bool { words.contains { text.contains($0) } }

        if has("docker-php-ext-install", "docker-php-ext-configure", "docker-php-ext-enable") { return .compilingPHPExtensions }
        if has("pecl install") { return .installingPECLExtensions }
        if has("composer install", "composer update", "installing dependencies from lock file",
               "updating dependencies", "generating autoload files") || text.hasPrefix("package operations:") {
            return .installingComposerPackages
        }
        if has("npm run build", "vite build", "building for production", "yarn build", "pnpm build", "bun run build") {
            return .buildingFrontEndAssets
        }
        if has("npm ci", "npm install", "npm i ") || text.hasPrefix("added ") && text.contains(" package") {
            return .installingJavaScriptPackages(manager: "npm")
        }
        if has("yarn install") { return .installingJavaScriptPackages(manager: "Yarn") }
        if has("pnpm install", "pnpm i ") { return .installingJavaScriptPackages(manager: "pnpm") }
        if has("bun install", "bun i ") { return .installingJavaScriptPackages(manager: "Bun") }
        if has("artisan db:seed", "database\\seeders", "seeding database") { return .seedingDatabase }
        if has("artisan migrate", "running migrations", "rails db:migrate", "manage.py migrate") { return .migratingDatabase }
        if has("bundle install") { return .installingRubyGems }
        if has("pip install", "uv sync", "poetry install", "pipenv install") { return .installingPythonPackages }
        // Cargo's own shape, `Compiling serde v1.0.200`, and not any line that starts with the
        // word: a C build of a PHP extension prints plenty of those.
        if has("cargo build") || text.range(of: #"^compiling [a-z0-9_\-]+ v[0-9]"#, options: .regularExpression) != nil {
            return .compilingRustCrates
        }
        if has("go mod download") { return .downloadingGoModules }
        if has("apt-get install", "apt install", "apk add", "dnf install", "yum install") { return .installingSystemPackages }
        if has("pulling fs layer", "pulling from ") || text.hasSuffix(" pulling") || text.hasSuffix(" pulled") {
            return .pullingDockerImages
        }
        if has("docker build", "docker compose build", "docker-compose build", "docker buildx build")
            || has("docker compose", "docker-compose") && text.contains(" build") {
            return .buildingDockerImage
        }
        if has("docker compose up", "docker-compose up") || text.hasPrefix("container ")
            && (text.hasSuffix(" started") || text.hasSuffix(" starting") || text.hasSuffix(" healthy") || text.hasSuffix(" created")) {
            return .startingContainers
        }
        if has("submodule") || text.hasPrefix("preparing this worktree's submodules") { return .preparingSubmodules }
        return nil
    }

    /// A line of a Docker build, traced back to the build step it belongs to.
    private static func dockerStep(_ line: String, before earlier: ArraySlice<String>) -> SetupStep? {
        // The classic builder: `Step 4/9 : RUN composer install`.
        if line.hasPrefix("Step "), let colon = line.range(of: " : ") {
            let command = String(line[colon.upperBound...])
            return SetupStep(activity(command) ?? .buildingDockerImage, isInsideDockerBuild: true)
        }
        // BuildKit: `#9 [agent 4/9] RUN ...` is the header, `#9 41.2 output` is everything after.
        guard line.hasPrefix("#"), let number = line.dropFirst().split(separator: " ", maxSplits: 1).first,
              number.allSatisfy(\.isNumber), !number.isEmpty else { return nil }
        let prefix = "#\(number) ["
        let header = line.hasPrefix(prefix) ? line : earlier.last { $0.hasPrefix(prefix) }
        guard let header, let close = header.range(of: "] ") else {
            return SetupStep(.buildingDockerImage)
        }
        let command = String(header[close.upperBound...])
        return SetupStep(activity(command) ?? .buildingDockerImage, isInsideDockerBuild: true)
    }

    /// Colour and cursor codes, which `docker compose` and `npm` print when they think they are
    /// talking to a terminal. Left in, `\u{1B}[1m#9 [agent 4/9]` does not begin with `#`.
    private static func strippingEscapes(_ line: String) -> String {
        guard line.contains("\u{1B}") else { return line }
        return line.replacingOccurrences(of: "\u{1B}\\[[0-9;?]*[ -/]*[@-~]", with: "", options: .regularExpression)
    }
}
