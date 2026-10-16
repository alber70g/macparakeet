import Foundation

/// Speaker samples and suggestions in an external transcriber's output folder,
/// and the paraspeakrs filename protocol that names them: the part after
/// `<speaker id>__` in a sample's file name is that speaker's name.
public struct ExternalSpeakerNaming: Sendable, Equatable {
    public static let separator = "__"
    public static let unnamed = "NAME-ME"
    /// Samples of dropped speakers; the tool only reads the folder's top level.
    public static let droppedFolderName = "dropped"

    public struct Speaker: Sendable, Equatable {
        public let externalID: String
        public let suggestedLabel: String?
        public let suggestionScore: Double?
        /// Current sample file, in the output folder or its `dropped/` folder.
        public let sampleURL: URL?

        public var transcriptID: String { ExternalSpeakerID.transcriptID(for: externalID) }

        public var isDropped: Bool {
            sampleURL?.deletingLastPathComponent().lastPathComponent == ExternalSpeakerNaming.droppedFolderName
        }

        /// The file-name part that marks an untouched voice-library guess.
        public var suggestionName: String? {
            guard let suggestedLabel, let suggestionScore else { return nil }
            return ExternalSpeakerNaming.safeName(suggestedLabel) + "_" + String(format: "%.2f", suggestionScore)
        }

        /// The voice-library suggestion is shown but nobody confirmed it yet.
        public var hasUnconfirmedSuggestion: Bool {
            guard let suggestionName, !isDropped else { return false }
            return currentName == suggestionName
        }

        public var currentName: String? {
            guard let sampleURL else { return nil }
            let stem = sampleURL.deletingPathExtension().lastPathComponent
            let prefix = externalID + ExternalSpeakerNaming.separator
            guard stem.hasPrefix(prefix) else { return nil }
            return String(stem.dropFirst(prefix.count))
        }
    }

    public let outputFolder: URL
    public let speakers: [Speaker]

    public func speaker(forTranscriptID id: String) -> Speaker? {
        guard let externalID = ExternalSpeakerID.externalID(fromTranscriptID: id) else { return nil }
        return speakers.first { $0.externalID == externalID }
    }

    /// Reads the output folder of a meeting transcribed externally, or nil
    /// when the meeting has none.
    public static func load(meetingFolder: URL) -> ExternalSpeakerNaming? {
        let outputFolder = ExternalTranscriberConfiguration.outputFolder(inMeetingFolder: meetingFolder)
        guard let transcript = try? ExternalTranscript.load(fromFolder: outputFolder) else { return nil }
        let ids = transcript.speakers.map(\.id)
        let files = sampleFiles(in: outputFolder, ids: ids)
            .merging(sampleFiles(in: outputFolder.appendingPathComponent(droppedFolderName), ids: ids)) { top, _ in top }
        let speakers = transcript.speakers.map { speaker in
            Speaker(
                externalID: speaker.id,
                suggestedLabel: speaker.suggestedLabel,
                suggestionScore: speaker.suggestionScore,
                sampleURL: files[speaker.id]
            )
        }
        return ExternalSpeakerNaming(outputFolder: outputFolder, speakers: speakers)
    }

    /// Matches the tool: longest ID first, so `L_SPEAKER_00` is never taken
    /// for a `SPEAKER_00` prefix.
    static func sampleFiles(in folder: URL, ids: [String]) -> [String: URL] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        let sortedIDs = ids.sorted { $0.count > $1.count }
        var files: [String: URL] = [:]
        for name in names.sorted() where name.lowercased().hasSuffix(".wav") {
            guard let id = sortedIDs.first(where: { name.hasPrefix($0 + separator) }), files[id] == nil else { continue }
            files[id] = folder.appendingPathComponent(name)
        }
        return files
    }

    /// Same rules as paraspeakrs's own `_safe`.
    public static func safeName(_ name: String) -> String {
        let cleaned = name
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: "\0", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? unnamed : cleaned
    }
}

// MARK: - Planning

extension ExternalSpeakerNaming {
    public enum Target: Sendable, Equatable {
        /// Leave the file alone (an untouched suggestion).
        case keep
        case named(String)
        case unnamed
        case dropped
    }

    /// Where each speaker's sample file should be for the tool to read the
    /// names MacParakeet currently shows (ADR-035 write-back rule).
    public func plan(attribution: EffectiveSpeakerAttribution) -> [String: Target] {
        let labels = Dictionary(attribution.speakers.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var targets: [String: Target] = [:]
        for speaker in speakers where speaker.sampleURL != nil {
            let id = speaker.transcriptID
            let assignments = attribution.editableSegments
                .filter { $0.automaticSpeakerIDs.contains(id) }
                .map(\.assignment)
            guard !assignments.isEmpty else {
                targets[speaker.externalID] = .dropped
                continue
            }
            guard let ownerID = Self.mostFrequentSpeaker(in: assignments, preferring: id),
                let owner = labels[ownerID]
            else {
                targets[speaker.externalID] = .unnamed
                continue
            }
            let label = owner.label.trimmingCharacters(in: .whitespacesAndNewlines)
            if owner.carriesAutomaticLabel || label.isEmpty {
                targets[speaker.externalID] = .unnamed
            } else if ownerID == id, speaker.hasUnconfirmedSuggestion, label == speaker.suggestedLabel {
                targets[speaker.externalID] = .keep
            } else {
                targets[speaker.externalID] = .named(label)
            }
        }
        return targets
    }

    private static func mostFrequentSpeaker(in assignments: [SpeakerAssignment], preferring preferred: String) -> String? {
        var counts: [String: Int] = [:]
        for case .speaker(let id) in assignments { counts[id, default: 0] += 1 }
        if let preferredCount = counts[preferred], preferredCount == counts.values.max() { return preferred }
        return counts.max { lhs, rhs in lhs.value == rhs.value ? lhs.key > rhs.key : lhs.value < rhs.value }?.key
    }

    /// The file a target puts the speaker's sample in.
    public func destination(for speaker: Speaker, target: Target) -> URL? {
        guard let sampleURL = speaker.sampleURL else { return nil }
        let prefix = speaker.externalID + Self.separator
        switch target {
        case .keep:
            return sampleURL
        case .named(let name):
            return outputFolder.appendingPathComponent(prefix + Self.safeName(name) + ".wav")
        case .unnamed:
            return outputFolder.appendingPathComponent(prefix + Self.unnamed + ".wav")
        case .dropped:
            let name = speaker.isDropped ? sampleURL.lastPathComponent : prefix + (speaker.currentName ?? Self.unnamed) + ".wav"
            return outputFolder.appendingPathComponent(Self.droppedFolderName).appendingPathComponent(name)
        }
    }

    /// Moves sample files to match the targets. Returns whether anything moved.
    @discardableResult
    public func applyFileMoves(_ targets: [String: Target], fileManager: FileManager = .default) throws -> Bool {
        var moved = false
        for speaker in speakers {
            guard let target = targets[speaker.externalID],
                let source = speaker.sampleURL,
                let destination = destination(for: speaker, target: target),
                destination.standardizedFileURL != source.standardizedFileURL
            else { continue }
            try fileManager.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try fileManager.moveItem(at: source, to: destination)
            moved = true
        }
        return moved
    }
}
