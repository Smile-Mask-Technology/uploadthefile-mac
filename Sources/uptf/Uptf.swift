import ArgumentParser
import Darwin
import UptfKit

struct Uptf: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "uptf",
        abstract: "Put files and folders online from the command line and get a link.",
        version: UptfKitVersion.value,
        subcommands: [
            Login.self, Logout.self, Status.self,
            Publish.self, Update.self, List.self, Info.self,
            Rename.self, Password.self, Gate.self, Expiry.self, Display.self, Delete.self,
        ])
}

/// The entry point. It must reach ArgumentParser's ASYNC `main()`: the synchronous overload
/// refuses an AsyncParsableCommand at launch ("Asynchronous root command needs availability
/// annotation"), and a top-level `Uptf.main()` in main.swift resolves to it. Pinned by
/// Tests/UptfKitTests/CLILaunchTests.swift, which runs the built binary.
@main
enum UptfEntryPoint {
    static func main() async {
        // A closed pipe (for example `uptf ls | head`) must not kill us with SIGPIPE mid-write.
        signal(SIGPIPE, SIG_IGN)
        await Uptf.main()
    }
}
