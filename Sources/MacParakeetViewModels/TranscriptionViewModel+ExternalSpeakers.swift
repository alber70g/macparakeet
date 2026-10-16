import Foundation
import MacParakeetCore

/// Speaker naming for transcriptions whose speakers an external detector such
/// as paraspeakrs found (ADR-035): sample playback data, suggestion
/// confirmation, dropping a speaker, and writing names back to the tool after
/// every committed speaker correction.
extension TranscriptionViewModel {
    public func externalSpeaker(for speakerID: String) -> ExternalSpeakerNaming.Speaker? {
        externalSpeakerNaming?.speaker(forTranscriptID: speakerID)
    }

    func refreshExternalSpeakerNaming(for transcription: Transcription) {
        let folder = ExternalSpeakerDetectionLocation.outputFolder(for: transcription)
        let token = UUID()
        externalSpeakerNamingLoadToken = token
        let transcriptionID = transcription.id
        Task { [weak self] in
            let (naming, detectionError) = await Task.detached(priority: .userInitiated) {
                (
                    ExternalSpeakerNaming.load(outputFolder: folder),
                    ExternalDiarizationService.lastError(inOutputFolder: folder)
                )
            }.value
            guard let self,
                self.externalSpeakerNamingLoadToken == token,
                self.currentTranscription?.id == transcriptionID
            else { return }
            self.externalSpeakerNaming = naming
            self.externalSpeakerDetectionError = detectionError
        }
    }

    func enqueueExternalSpeakerWriteBack(
        transcriptionID: UUID,
        attribution: EffectiveSpeakerAttribution
    ) {
        guard let writeBack = externalSpeakerWriteBack else { return }
        let transcription: Transcription?
        if let current = currentTranscription, current.id == transcriptionID {
            // Nothing to write back to for a transcript the built-in
            // diarizer produced.
            guard externalSpeakerNaming != nil else { return }
            transcription = current
        } else {
            transcription = (try? transcriptionRepo?.fetch(id: transcriptionID)) ?? nil
        }
        guard let transcription else { return }
        let folder = ExternalSpeakerDetectionLocation.outputFolder(for: transcription)
        runExternalSpeakerWriteBack(transcriptionID: transcriptionID) {
            try await writeBack.sync(
                transcriptionID: transcriptionID,
                outputFolder: folder,
                attribution: attribution
            )
        }
    }

    /// Accepts the voice-library suggestion as the speaker's name and teaches
    /// the tool's voice library.
    public func confirmExternalSpeakerSuggestion(speakerID: String) {
        guard let writeBack = externalSpeakerWriteBack,
            let transcription = currentTranscription
        else { return }
        let folder = ExternalSpeakerDetectionLocation.outputFolder(for: transcription)
        let transcriptionID = transcription.id
        runExternalSpeakerWriteBack(transcriptionID: transcriptionID) {
            try await writeBack.confirmSuggestion(
                transcriptionID: transcriptionID,
                outputFolder: folder,
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
