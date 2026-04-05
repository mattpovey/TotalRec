import Foundation
import Speech

protocol AudioTranscribing: AnyObject {
    func transcribeFile(
        at url: URL,
        localeID: String,
        onDevicePreferred: Bool,
        onProgress: @escaping (String) -> Void,
        completion: @escaping (Result<String, Error>) -> Void
    )
}

final class FileTranscriber: AudioTranscribing {
    private var task: SFSpeechRecognitionTask?

    func transcribeFile(at url: URL,
                        localeID: String = Locale.current.identifier,
                        onDevicePreferred: Bool = true,
                        onProgress: @escaping (String) -> Void,
                        completion: @escaping (Result<String, Error>) -> Void) {
        Task { [weak self] in
            let status = await self?.requestSpeechAuthAsync() ?? .denied
            guard status == .authorized else {
                completion(.failure(NSError(domain: "STT", code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "Speech permission denied"])))
                return
            }
            self?.startRecognition(url: url, localeID: localeID, onDevicePreferred: onDevicePreferred, onProgress: onProgress, completion: completion)
        }
    }

    private func startRecognition(url: URL,
                                  localeID: String,
                                  onDevicePreferred: Bool,
                                  onProgress: @escaping (String) -> Void,
                                  completion: @escaping (Result<String, Error>) -> Void) {
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: localeID)),
              recognizer.isAvailable else {
            completion(.failure(NSError(domain: "STT", code: -2,
                userInfo: [NSLocalizedDescriptionKey: "Recognizer unavailable"])))
            return
        }

        let req = SFSpeechURLRecognitionRequest(url: url)
        req.shouldReportPartialResults = true
        if onDevicePreferred, recognizer.supportsOnDeviceRecognition {
            req.requiresOnDeviceRecognition = true
        }

        var lastEmitted = ""

        self.task = recognizer.recognitionTask(with: req) { [weak self] result, error in
            if let error = error {
                self?.task = nil
                completion(.failure(error))
                return
            }
            guard let result = result else { return }

            let full = result.bestTranscription.formattedString
            if full.count > lastEmitted.count {
                lastEmitted = full
                onProgress(full)
            }

            if result.isFinal {
                self?.task = nil
                completion(.success(full))
            }
        }
    }

    private func requestSpeechAuthAsync() async -> SFSpeechRecognizerAuthorizationStatus {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }
    }
}
