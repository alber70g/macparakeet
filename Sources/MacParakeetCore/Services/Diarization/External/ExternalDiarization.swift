import Foundation

/// The `diarization.json` an external speaker detector writes into its output
/// folder (contract: `spec/contracts/external-diarizer-v1.md`). Times are
/// seconds. Unknown keys are ignored so tools can add fields.
public struct ExternalDiarization: Codable, Sendable, Equatable {
    public static let fileName = "diarization.json"
    public static let supportedVersion = 1

    public struct Speaker: Codable, Sendable, Equatable {
        public var id: String
        /// The name to show: chosen by a person (`named`) or a voice-library
        /// guess (`suggestion`). Nil when unnamed.
        public var label: String?
        public var labelSource: String?
        public var suggestedLabel: String?
        public var suggestionScore: Double?
        /// Sample audio for this speaker, relative to the output folder.
        public var sampleFile: String?
        public var excluded: Bool?

        public init(
            id: String,
            label: String? = nil,
            labelSource: String? = nil,
            suggestedLabel: String? = nil,
            suggestionScore: Double? = nil,
            sampleFile: String? = nil,
            excluded: Bool? = nil
        ) {
            self.id = id
            self.label = label
            self.labelSource = labelSource
            self.suggestedLabel = suggestedLabel
            self.suggestionScore = suggestionScore
            self.sampleFile = sampleFile
            self.excluded = excluded
        }

        enum CodingKeys: String, CodingKey {
            case id, label, excluded
            case labelSource = "label_source"
            case suggestedLabel = "suggested_label"
            case suggestionScore = "suggestion_score"
            case sampleFile = "sample_file"
        }
    }

    public struct Turn: Codable, Sendable, Equatable {
        public var speaker: String
        public var start: Double
        public var end: Double

        public init(speaker: String, start: Double, end: Double) {
            self.speaker = speaker
            self.start = start
            self.end = end
        }
    }

    public var version: Int
    public var speakers: [Speaker]
    public var turns: [Turn]

    public init(version: Int = Self.supportedVersion, speakers: [Speaker], turns: [Turn]) {
        self.version = version
        self.speakers = speakers
        self.turns = turns
    }

    public enum ParseError: Error, LocalizedError, Equatable {
        case missing(path: String)
        case invalid(String)
        case unsupportedVersion(Int)

        public var errorDescription: String? {
            switch self {
            case .missing(let path):
                return "The speaker detection command did not write \(path)."
            case .invalid(let detail):
                return "The speaker detection command wrote an unreadable diarization.json: \(detail)"
            case .unsupportedVersion(let version):
                return
                    "The speaker detection command wrote diarization.json version \(version); version \(ExternalDiarization.supportedVersion) is supported."
            }
        }
    }

    public static func load(fromFolder folderURL: URL) throws -> ExternalDiarization {
        let url = folderURL.appendingPathComponent(fileName)
        guard let data = FileManager.default.contents(atPath: url.path) else {
            throw ParseError.missing(path: url.path)
        }
        return try decode(data)
    }

    public static func decode(_ data: Data) throws -> ExternalDiarization {
        let diarization: ExternalDiarization
        do {
            diarization = try JSONDecoder().decode(ExternalDiarization.self, from: data)
        } catch {
            throw ParseError.invalid(error.localizedDescription)
        }
        guard diarization.version == supportedVersion else {
            throw ParseError.unsupportedVersion(diarization.version)
        }
        return diarization
    }

    /// The speakers and turns in MacParakeet's diarization terms. Excluded
    /// speakers and turns of unknown speakers are left out; speakers keep the
    /// detector's IDs. A speaker the detector named keeps that name; an
    /// unnamed one gets "Speaker N", which the app treats as unnamed.
    public func result() -> MacParakeetDiarizationResult {
        let included = speakers.filter { $0.excluded != true }
        let includedIDs = Set(included.map(\.id))
        let segments =
            turns
            .filter { includedIDs.contains($0.speaker) && $0.end > $0.start }
            .map {
                SpeakerSegment(
                    speakerId: $0.speaker,
                    startMs: Int(($0.start * 1000).rounded()),
                    endMs: Int(($0.end * 1000).rounded())
                )
            }
            .sorted { ($0.startMs, $0.speakerId) < ($1.startMs, $1.speakerId) }

        var speechMs: [String: Int] = [:]
        for segment in segments {
            speechMs[segment.speakerId, default: 0] += segment.endMs - segment.startMs
        }
        let speaking = included.filter { speechMs[$0.id] != nil }
        var suppliedLabels: [String: String] = [:]
        let infos = speaking.enumerated().map { index, speaker in
            let label = speaker.label?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !label.isEmpty { suppliedLabels[speaker.id] = label }
            return SpeakerInfo(id: speaker.id, label: label.isEmpty ? "Speaker \(index + 1)" : label)
        }
        return MacParakeetDiarizationResult(
            segments: segments,
            speakerCount: infos.count,
            speakers: infos,
            speechMsBySpeaker: speechMs,
            suppliedLabels: suppliedLabels
        )
    }
}
