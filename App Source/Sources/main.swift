import Foundation
import SwiftUI

if CommandLine.arguments.contains("--cli") {
    exit(runCLI(CommandLine.arguments))
}
DCBReaderApp.main()
