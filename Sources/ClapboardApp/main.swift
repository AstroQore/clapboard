import ClapboardCore
import Foundation

// Headless modes never touch AppKit. A SwiftUI app restores its windows before
// `applicationDidFinishLaunching` runs, and when the executable is started
// from a shell that restoration can block forever in window layout — which
// made every `--list-devices` / `--engine-test` hang after the GUI had been
// opened once. Dispatching here, before `NSApplicationMain`, sidesteps it.
let headlessArguments = Array(CommandLine.arguments.dropFirst())
if HeadlessCommand.matches(headlessArguments) {
    MainActor.assumeIsolated { HeadlessCommand.run(headlessArguments) }
}
ClapboardApp.main()
