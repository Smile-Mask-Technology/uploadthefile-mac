// The entry point. `App.main()` rather than `@main` so this file name stays the executable's `main`.
import Foundation

#if DEBUG
// Debug builds only: draw every screen state to PNG files and exit (see Snapshots.swift).
if let directory = Snapshots.requestedDirectory(CommandLine.arguments) {
    exit(Snapshots.run(into: directory))
}
#endif

UploadTheFileApp.main()
