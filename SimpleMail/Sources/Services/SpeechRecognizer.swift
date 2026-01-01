import Foundation
import Speech
import AVFoundation

/// Handles speech recognition for voice search
@MainActor
final class SpeechRecognizer: ObservableObject {
    @Published var transcript = ""
    @Published var isListening = false
    @Published var error: String?

    private var audioEngine: AVAudioEngine?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private let speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))

    /// Request authorization for speech recognition
    func requestAuthorization() async -> Bool {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
    }

    /// Start listening for speech
    func startListening() {
        guard !isListening else { return }

        // Reset state
        transcript = ""
        error = nil

        // Check authorization
        Task {
            let authorized = await requestAuthorization()
            guard authorized else {
                error = "Speech recognition not authorized"
                return
            }

            do {
                try await startRecording()
            } catch {
                self.error = error.localizedDescription
                isListening = false
            }
        }
    }

    /// Stop listening
    func stopListening() {
        audioEngine?.stop()
        audioEngine?.inputNode.removeTap(onBus: 0)
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()

        audioEngine = nil
        recognitionRequest = nil
        recognitionTask = nil
        isListening = false
    }

    private func startRecording() async throws {
        // Configure audio session
        let audioSession = AVAudioSession.sharedInstance()
        try audioSession.setCategory(.record, mode: .measurement, options: .duckOthers)
        try audioSession.setActive(true, options: .notifyOthersOnDeactivation)

        audioEngine = AVAudioEngine()
        guard let audioEngine = audioEngine else {
            throw RecognitionError.audioEngineFailure
        }

        recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
        guard let recognitionRequest = recognitionRequest else {
            throw RecognitionError.requestFailure
        }

        recognitionRequest.shouldReportPartialResults = true

        guard let speechRecognizer = speechRecognizer, speechRecognizer.isAvailable else {
            throw RecognitionError.recognizerUnavailable
        }

        recognitionTask = speechRecognizer.recognitionTask(with: recognitionRequest) { [weak self] result, error in
            Task { @MainActor in
                guard let self = self else { return }

                if let result = result {
                    self.transcript = result.bestTranscription.formattedString
                }

                if error != nil || result?.isFinal == true {
                    self.stopListening()
                }
            }
        }

        let inputNode = audioEngine.inputNode
        let recordingFormat = inputNode.outputFormat(forBus: 0)

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { buffer, _ in
            self.recognitionRequest?.append(buffer)
        }

        audioEngine.prepare()
        try audioEngine.start()

        isListening = true
    }

    enum RecognitionError: LocalizedError {
        case audioEngineFailure
        case requestFailure
        case recognizerUnavailable

        var errorDescription: String? {
            switch self {
            case .audioEngineFailure:
                return "Failed to initialize audio engine"
            case .requestFailure:
                return "Failed to create recognition request"
            case .recognizerUnavailable:
                return "Speech recognizer is not available"
            }
        }
    }
}
