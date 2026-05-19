import Foundation
import GRDB

enum ChatDB {
    static var url: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Messages/chat.db", isDirectory: false)
    }

    static func open() throws -> DatabasePool {
        var config = Configuration()
        config.readonly = true
        config.label = "chat.db"
        return try DatabasePool(path: url.path, configuration: config)
    }

    static func looksLikePermissionError(_ error: Error) -> Bool {
        if let dbError = error as? DatabaseError {
            switch dbError.resultCode {
            case .SQLITE_CANTOPEN, .SQLITE_PERM, .SQLITE_AUTH, .SQLITE_NOTADB:
                return true
            default:
                break
            }
        }
        let ns = error as NSError
        return ns.code == NSFileReadNoPermissionError || ns.code == NSFileNoSuchFileError
    }
}
