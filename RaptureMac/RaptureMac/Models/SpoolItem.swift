import Foundation

/// One queued capture in the internal spool (see `SpoolStore`): a self-describing
/// directory holding the capture text, its metadata, and any attachments copied at
/// spool time.
struct SpoolItem: Sendable, Equatable {
    /// The item's directory inside the spool root. Its name (`<seq>-<timestamp>`)
    /// is the item's identity in `SpoolFiledLedger`.
    let directory: URL
    let metadata: SpoolMetadata

    var name: String { directory.lastPathComponent }
    var captureTextURL: URL { directory.appendingPathComponent(SpoolStore.captureTextFilename) }
    var metadataURL: URL { directory.appendingPathComponent(SpoolStore.metadataFilename) }
    var attachmentsDirectory: URL {
        directory.appendingPathComponent(SpoolStore.attachmentsDirectoryName, isDirectory: true)
    }
}

/// Everything a flush needs to file the capture with authoritative frontmatter —
/// nothing about the note is re-inferred from the spool file's name or mtime.
struct SpoolMetadata: Codable, Sendable, Equatable {
    /// Format version for forward compatibility.
    var version: Int
    /// The capture's own timestamp; becomes the note's `captured` frontmatter and
    /// filename date verbatim.
    var capturedAt: Date
    /// Which app captured the note; becomes the `source` frontmatter verbatim.
    var source: CaptureSource
    /// Monotonic queue position (never reused; see `PersistedState.spoolNextSeq`).
    var seq: Int
    var spooledAt: Date
    /// Attachment source paths that could not be copied at spool time; the flush
    /// re-reports these as missing.
    var failedAttachments: [String]

    enum CodingKeys: String, CodingKey {
        case version, capturedAt, source, seq, spooledAt, failedAttachments
    }

    init(
        version: Int = 1,
        capturedAt: Date,
        source: CaptureSource,
        seq: Int,
        spooledAt: Date,
        failedAttachments: [String] = []
    ) {
        self.version = version
        self.capturedAt = capturedAt
        self.source = source
        self.seq = seq
        self.spooledAt = spooledAt
        self.failedAttachments = failedAttachments
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        self.capturedAt = try c.decode(Date.self, forKey: .capturedAt)
        self.source = try c.decodeIfPresent(CaptureSource.self, forKey: .source) ?? .raptureMac
        self.seq = try c.decodeIfPresent(Int.self, forKey: .seq) ?? 0
        self.spooledAt = try c.decodeIfPresent(Date.self, forKey: .spooledAt) ?? capturedAt
        self.failedAttachments = try c.decodeIfPresent([String].self, forKey: .failedAttachments) ?? []
    }
}
