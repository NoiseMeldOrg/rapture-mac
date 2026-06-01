import Foundation

extension Bundle {
    /// The bundled `Scripts/` directory inside `Contents/Resources/`.
    /// Populated at build time by `Scripts/copy-integrations-resources.sh`.
    var scriptsURL: URL {
        resourceURL!.appendingPathComponent("Scripts", isDirectory: true)
    }

    /// The bundled `examples/` directory inside `Contents/Resources/`.
    /// Populated at build time by `Scripts/copy-integrations-resources.sh`.
    var examplesURL: URL {
        resourceURL!.appendingPathComponent("examples", isDirectory: true)
    }
}
