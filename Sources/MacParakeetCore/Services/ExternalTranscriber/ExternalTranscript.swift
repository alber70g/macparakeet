import Foundation

/// The `transcript.json` an external transcriber writes into its output
/// folder (contract: `spec/contracts/external-transcriber-v1.md`). Times are
/// seconds. Unknown keys are ignored so tools can add fields.
public struct ExternalTranscript: Codable, Sendable, Equatable {
    public static let fileName = "transcript.json"
    public static let supportedVersion = 1

    public struct Speaker: Codable, Sendable, Equatable {
        public var id: String
        public var label: String?
        /// `named` (chosen by a person), `suggestion` (voice-library guess)
        /// or nil (unnamed).
        public var labelSource: String?
        public var suggestedLabel: String?
        public var suggestionScore: Double?
        /// Sample audio for this speaker, relative to the output folder.
        public var sampleFile: String?
        public var excluded: Bool?

        public var isSuggestion: Bool { labelSource == "suggestion" }

        enum CodingKeys: String, CodingKey {
            case id, label, excluded
            case labelSource = "label_source"
            case suggestedLabel = "suggested_label"
            case suggestionScore = "suggestion_score"
            case sampleFile = "sample_file"
        }
    }

    public struct Word: Codable, Sendable, Equatable {
        public var word: String
        public var start: Double
        public var end: Double
    }

    public struct Segment: Codable, Sendable, Equatable {
        public var speaker: String?
        public var start: Double
        public var end: Double
        public var text: String
        public var words: [Word]?
    }

    public var version: Int
    public var language: String?
    public var speakers: [Speaker]
    public var segments: [Segment]

    public enum ParseError: Error, LocalizedError, Equatable {
        case missing(path: String)
        case invalid(String)
        case unsupportedVersion(Int)

        public var errorDescription: String? {
            switch self {
            case .missing(let path):
                return "The external transcriber did not write \(path)."
            case .invalid(let detail):
                return "The external transcriber wrote an unreadable transcript.json: \(detail)"
            case .unsupportedVersion(let version):
                return
                    "The external transcriber wrote transcript.json version \(version); version \(ExternalTranscript.supportedVersion) is supported."
            }
        }
    }

    public static func load(fromFolder folderURL: URL) throws -> ExternalTranscript {
        let url = folderURL.appendingPathComponent(fileName)
        guard let data = FileManager.default.contents(atPath: url.path) else {
            throw ParseError.missing(path: url.path)
        }
        return try decode(data)
    }

    public static func decode(_ data: Data) throws -> ExternalTranscript {
        let transcript: ExternalTranscript
        do {
            transcript = try JSONDecoder().decode(ExternalTranscript.self, from: data)
        } catch {
            throw ParseError.invalid(String(describing: error))
        }
        guard transcript.version == supportedVersion else {
            throw ParseError.unsupportedVersion(transcript.version)
        }
        return transcript
    }
}

// MARK: - Speaker identity

public enum ExternalSpeakerID {
    /// Prefix that keeps external speaker IDs apart from the built-in
    /// `microphone`/`system` roster IDs, which carry their own semantics.
    public static let prefix = "external:"

    public static func transcriptID(for externalID: String) -> String {
        prefix + externalID
    }

    /// The tool's own speaker ID, or nil for a roster entry it did not create.
    public static func externalID(fromTranscriptID id: String) -> String? {
        guard id.hasPrefix(prefix) else { return nil }
        return String(id.dropFirst(prefix.count))
    }
}

// MARK: - Conversion

extension ExternalTranscript {
    /// Transcript data in MacParakeet's shape. Words without a known speaker
    /// stay unattributed. A segment without words becomes one token spanning
    /// the segment, so its text is never given invented word timings.
    public struct Imported: Sendable, Equatable {
        public let rawTranscript: String
        public let words: [WordTimestamp]
        public let speakers: [SpeakerInfo]
        public let diarizationSegments: [DiarizationSegmentRecord]
    }

    public func imported() -> Imported {
        let roster = speakers.filter { $0.excluded != true }
        let knownIDs = Set(roster.map(\.id))
        var words: [WordTimestamp] = []
        for segment in segments.sorted(by: { $0.start < $1.start }) {
            let speakerID = segment.speaker
                .flatMap { knownIDs.contains($0) ? ExternalSpeakerID.transcriptID(for: $0) : nil }
            let segmentWords = (segment.words ?? []).filter {
                !$0.word.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
            if segmentWords.isEmpty {
                let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                words.append(Self.timestamp(text, segment.start, segment.end, speakerID))
            } else {
                words.append(
                    contentsOf: segmentWords.map {
                        Self.timestamp($0.word, $0.start, $0.end, speakerID)
                    })
            }
        }

        let activeIDs = Set(words.compactMap(\.speakerId))
        var infos: [SpeakerInfo] = []
        for (index, speaker) in roster.enumerated() {
            let id = ExternalSpeakerID.transcriptID(for: speaker.id)
            guard activeIDs.contains(id) else { continue }
            let label = speaker.label?.trimmingCharacters(in: .whitespacesAndNewlines)
            infos.append(SpeakerInfo(id: id, label: label?.isEmpty == false ? label! : "Speaker \(index + 1)"))
        }

        return Imported(
            rawTranscript: MeetingTranscriptFinalizer.transcriptText(from: words),
            words: words,
            speakers: infos,
            // Unattributed words are skipped: the finalizer's builder stops at
            // a first word without a speaker, and tools often open with one.
            diarizationSegments: MeetingTranscriptFinalizer.buildDiarizationSegments(
                from: words.filter { $0.speakerId != nil }
            )
        )
    }

    private static func timestamp(_ text: String, _ start: Double, _ end: Double, _ speakerID: String?) -> WordTimestamp
    {
        let startMs = max(0, Int((start * 1000).rounded()))
        return WordTimestamp(
            word: text.trimmingCharacters(in: .whitespacesAndNewlines),
            startMs: startMs,
            endMs: max(startMs, Int((end * 1000).rounded())),
            confidence: 1.0,
            speakerId: speakerID
        )
    }
}
