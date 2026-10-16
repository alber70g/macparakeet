import Foundation
import MacParakeetCore

/// Speaker naming for meetings the external transcriber produced (ADR-035):
/// sample playback data, suggestion confirmation, dropping a speaker, and
/// writing names back to the tool after every committed speaker correction.
extension TranscriptionViewModel {
    /// The meeting folder of a transcript the external transcriber produced.
    static func externalMeetingFolder(for transcription: Transcription) -> URL? {
        guard transcription.sourceType == .meeting,
            transcription.engine == ExternalTranscriberConfiguration.engineName,
            let path = transcription.meetingArtifactFolderPath
        else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    public func externalSpeaker(for speakerID: String) -> ExternalSpeakerNaming.Speaker? {
        externalSpeakerNaming?.speaker(forTranscriptID: speakerID)
    }

    func refreshExternalSpeakerNaming(for transcription: Transcription) {
        guard let folder = Self.externalMeetingFolder(for: transcription) else {
            externalSpeakerNaming = nil
            return
        }
        let token = UUID()
        externalSpeakerNamingLoadToken = token
        let transcriptionID = transcription.id
        Task { [weak self] in
            let naming = await Task.detached(priority: .userInitiated) {
                ExternalSpeakerNaming.load(meetingFolder: folder)
            }.value
            guard let self,
                self.externalSpeakerNamingLoadToken == token,
                self.currentTranscription?.id == transcriptionID
            else { return }
            self.externalSpeakerNaming = naming
        }
    }

    func enqueueExternalSpeakerWriteBack(
        transcriptionID: UUID,
        attribution: EffectiveSpeakerAttribution
    ) {
        guard let writeBack = externalSpeakerWriteBack,
            let transcription = currentTranscription?.id == transcriptionID
                ? currentTranscription
                : (try? transcriptionRepo?.fetch(id: transcriptionID)) ?? nil,
            let folder = Self.externalMeetingFolder(for: transcription)
        else { return }
        runExternalSpeakerWriteBack(transcriptionID: transcriptionID) {
            try await writeBack.sync(
                meetingID: transcriptionID,
                meetingFolder: folder,
                attribution: attribution
            )
        }
    }

    /// Accepts the voice-library suggestion as the speaker's name and teaches
    /// the tool's voice library.
    public func confirmExternalSpeakerSuggestion(speakerID: String) {
        guard let writeBack = externalSpeakerWriteBack,
            let transcription = currentTranscription,
            let folder = Self.externalMeetingFolder(for: transcription)
        else { return }
        let transcriptionID = transcription.id
        runExternalSpeakerWriteBack(transcriptionID: transcriptionID) {
            try await writeBack.confirmSuggestion(
                meetingID: transcriptionID,
                meetingFolder: folder,
                transcriptSpeakerID: speakerID
            )
        }
    }

    /// Removes every line the speaker spoke, then the speaker. Write-back
    /// then moves the sample to `dropped/`, so the tool drops them too. Both
    /// steps are ordinary corrections and can be undone.
    @discardableResult
    public func dropExternalSpeaker(speakerID: String) async -> Bool {
        guard let attribution = speakerAttribution else { return false }
        let omissions = attribution.editableSegments
            .filter { $0.assignment == .speaker(id: speakerID) }
            .map {
                TranscriptTextChange.omit(
                    target: SpeakerCorrectionTarget(
                        anchorTranscriptSegmentIDs: $0.anchorTranscriptSegmentIDs,
                        wordRange: $0.wordRange
                    )
                )
            }
        if !omissions.isEmpty {
            guard await applySpeakerCorrectionAndWait(.reviseText(changes: omissions)) else { return false }
        }
        return await applySpeakerCorrectionAndWait(.remove(speakerID: speakerID, reassignTo: .unassigned))
    }

    /// Runs write-backs one after another, in commit order.
    private func runExternalSpeakerWriteBack(
        transcriptionID: UUID,
        _ operation: @escaping @Sendable () async throws -> Void
    ) {
        let previous = externalSpeakerWriteBackTask
        pendingExternalSpeakerWriteBacks += 1
        isWritingBackExternalSpeakers = true
        externalSpeakerWriteBackTask = Task { [weak self] in
            await previous?.value
            var failure: String?
            do {
                try await operation()
            } catch {
                failure = error.localizedDescription
            }
            guard let self else { return }
            self.pendingExternalSpeakerWriteBacks -= 1
            self.isWritingBackExternalSpeakers = self.pendingExternalSpeakerWriteBacks > 0
            guard let current = self.currentTranscription, current.id == transcriptionID else { return }
            self.externalSpeakerWriteBackError = failure
            self.refreshExternalSpeakerNaming(for: current)
        }
    }
}
