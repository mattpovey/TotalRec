import Foundation
import AVFoundation
import ScreenCaptureKit

protocol AudioRecording: AnyObject {
    func startRecording(to url: URL, onPermissionNeeded: @escaping () -> Void) async throws
    func stopRecording(completion: @escaping (Result<URL, Error>) -> Void)
}

final class SystemAudioRecorder: NSObject, AudioRecording, SCStreamOutput, AVCaptureAudioDataOutputSampleBufferDelegate {
    private var writer: AVAssetWriter?
    private var systemInput: AVAssetWriterInput?
    private var micInput: AVAssetWriterInput?

    private var stream: SCStream?
    private let scQueue = DispatchQueue(label: "SystemAudioRecorder.system")

    private var captureSession: AVCaptureSession?
    private let micQueue = DispatchQueue(label: "SystemAudioRecorder.mic")

    func startRecording(to url: URL, onPermissionNeeded: @escaping () -> Void) async throws {
        // We write a temporary .mov with 2 audio tracks, then mix down later.
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)

        let aacStereo: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVNumberOfChannelsKey: 2,
            AVSampleRateKey: 48_000,
            AVEncoderBitRateKey: 192_000
        ]
        let aacMono: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVNumberOfChannelsKey: 1,
            AVSampleRateKey: 48_000,
            AVEncoderBitRateKey: 128_000
        ]

        let sysIn = AVAssetWriterInput(mediaType: .audio, outputSettings: aacStereo)
        sysIn.expectsMediaDataInRealTime = true
        if !writer.canAdd(sysIn) { throw NSError(domain: "Writer", code: -10) }
        writer.add(sysIn)

        let micIn = AVAssetWriterInput(mediaType: .audio, outputSettings: aacMono)
        micIn.expectsMediaDataInRealTime = true
        if !writer.canAdd(micIn) { throw NSError(domain: "Writer", code: -11) }
        writer.add(micIn)

        self.writer = writer
        self.systemInput = sysIn
        self.micInput = micIn

        // --- System audio (ScreenCaptureKit) ---
        let content = try await SCShareableContent.current
        guard let display = content.displays.first else {
            throw NSError(domain: "ScreenCaptureKit", code: -20, userInfo: [NSLocalizedDescriptionKey: "No display found"])
        }

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let cfg = SCStreamConfiguration()
        cfg.capturesAudio = true
        cfg.sampleRate = 48_000
        cfg.channelCount = 2

        let stream = SCStream(filter: filter, configuration: cfg, delegate: nil)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: scQueue)
        self.stream = stream

        // --- Microphone (AVCapture) ---
        let session = AVCaptureSession()
#if os(iOS)
        session.automaticallyConfiguresApplicationAudioSession = false
#endif

        guard let mic = AVCaptureDevice.default(for: .audio) else {
            throw NSError(domain: "AVCapture", code: -30, userInfo: [NSLocalizedDescriptionKey: "No microphone available"])
        }
        let micInputDevice = try AVCaptureDeviceInput(device: mic)
        if !session.canAddInput(micInputDevice) { throw NSError(domain: "AVCapture", code: -31) }
        session.addInput(micInputDevice)

        let micOutput = AVCaptureAudioDataOutput()
        micOutput.setSampleBufferDelegate(self, queue: micQueue)
        if !session.canAddOutput(micOutput) { throw NSError(domain: "AVCapture", code: -32) }
        session.addOutput(micOutput)

        self.captureSession = session

        // Start both
        session.startRunning()
        do {
            try await stream.startCapture()
        } catch {
            onPermissionNeeded()
            throw error
        }
    }

    func stopRecording(completion: @escaping (Result<URL, Error>) -> Void) {
        guard let writer = writer else {
            completion(.failure(NSError(domain: "Recorder", code: -40))); return
        }

        let group = DispatchGroup()

        if let stream = stream {
            group.enter()
            stream.stopCapture { _ in group.leave() }
        }

        if let session = captureSession {
            group.enter()
            session.stopRunning()
            group.leave()
        }

        group.notify(queue: .main) {
            self.systemInput?.markAsFinished()
            self.micInput?.markAsFinished()
            writer.finishWriting { [weak self] in
                let url = writer.outputURL
                self?.cleanup()
                if writer.status == .completed {
                    completion(.success(url))
                } else {
                    completion(.failure(writer.error ?? NSError(domain: "Writer", code: -41)))
                }
            }
        }
    }

    private func cleanup() {
        stream = nil
        captureSession = nil
        writer = nil
        systemInput = nil
        micInput = nil
    }

    private func ensureWriterStarted(with firstPTS: CMTime) {
        guard let writer = writer, writer.status == .unknown else { return }
        writer.startWriting()
        writer.startSession(atSourceTime: firstPTS)
    }

    // System audio
    func stream(_ stream: SCStream,
                didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of outputType: SCStreamOutputType) {
        guard outputType == .audio,
              sampleBuffer.isValid,
              let input = systemInput else { return }

        if writer?.status == .unknown {
            let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            ensureWriterStarted(with: pts)
        }
        if input.isReadyForMoreMediaData { _ = input.append(sampleBuffer) }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        print("SCStream stopped: \(error)")
    }

    // Microphone
    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard sampleBuffer.isValid, let input = micInput else { return }

        if writer?.status == .unknown {
            let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            ensureWriterStarted(with: pts)
        }
        if input.isReadyForMoreMediaData { _ = input.append(sampleBuffer) }
    }
}
