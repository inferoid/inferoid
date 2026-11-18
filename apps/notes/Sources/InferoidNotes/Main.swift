import Foundation
import InferoidNotesKit

@main
enum Entry {
    @MainActor
    static func main() {
        let args = CommandLine.arguments
        if args.count > 1, args[1].hasPrefix("--") {
            Task {
                do { try await Headless.run(Array(args.dropFirst())) } catch {
                    FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8))
                    exit(1)
                }
                exit(0)
            }
            dispatchMain()
        }
        InferoidNotesApp.main()
    }
}
