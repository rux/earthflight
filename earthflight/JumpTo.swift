import AVFoundation
import Foundation
import MapKit
import Observation
import Speech

@MainActor
@Observable
final class JumpTo {
    enum Phase: Equatable {
        case idle
        case preparingSpeech
        case listening
        case searching
        case resolvingElevation
        case readyToJump
    }

    struct Destination {
        let longitudeDegrees: Double
        let latitudeDegrees: Double
        let groundEllipsoidHeightMeters: Double
    }

    private struct ElevationResponse: Decodable {
        struct Result: Decodable {
            let elevation: Double
        }

        let results: [Result]
        let status: String
    }

    private enum JumpError: Error {
        case permissionDenied
        case unsupportedTranscriptionLocale
        case emptyTranscript
        case noMapResult
        case elevationHTTP(Int)
        case elevationStatus(String)
        case malformedElevation
        case timeout
    }

    private(set) var phase: Phase = .idle
    private(set) var transcript = ""
    private var pendingDestination: Destination?
    private var operationTask: Task<Void, Never>?
    private var lastTranscriptChange: ContinuousClock.Instant?

    var isActive: Bool { phase != .idle }

    var displayPrompt: String {
        switch phase {
        case .idle: ""
        case .preparingSpeech: "Preparing speech…"
        case .listening: "Jump to…"
        case .searching: "Finding \(transcript)…"
        case .resolvingElevation: "Locating \(transcript)…"
        case .readyToJump: "Jumping to \(transcript)…"
        }
    }

    func start() {
        guard !isActive else { return }
        transcript = ""
        lastTranscriptChange = nil
        phase = .preparingSpeech
        operationTask = Task { [weak self] in
            guard let self else { return }
            do {
                let query = try await self.captureTranscript()
                self.transcript = query
                self.phase = .searching
                let item = try await self.firstMapItem(for: query)
                self.phase = .resolvingElevation
                let destination = try await self.resolveDestination(from: item)
                self.pendingDestination = destination
                self.phase = .readyToJump
            } catch is CancellationError {
                self.finish()
            } catch {
                self.report(error)
                self.finish()
            }
        }
    }

    func takePendingDestination() -> Destination? {
        guard let destination = pendingDestination else { return nil }
        pendingDestination = nil
        finish()
        return destination
    }

    private func captureTranscript() async throws -> String {
        guard await AVCaptureDevice.requestAccess(for: .audio) else {
            throw JumpError.permissionDenied
        }
        let speechAuthorization = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
        guard speechAuthorization == .authorized else {
            throw JumpError.permissionDenied
        }

        let preferredLocale = Locale(identifier: "en-GB")
        guard let recognizer = SFSpeechRecognizer(locale: preferredLocale) ??
            SFSpeechRecognizer(locale: .current) else {
            throw JumpError.unsupportedTranscriptionLocale
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true
        let audioEngine = AVAudioEngine()
        let inputNode = audioEngine.inputNode
        let results = AsyncThrowingStream<String, Error> { continuation in
            let task = recognizer.recognitionTask(with: request) { result, error in
                if let result {
                    continuation.yield(result.bestTranscription.formattedString)
                    if result.isFinal {
                        continuation.finish()
                    }
                }
                if let error {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }

        try inputNode.installAudioTap(
            onBus: 0,
            bufferSize: 1_024,
            format: inputNode.outputFormat(forBus: 0)
        ) { buffer, _ in
            request.append(AVAudioPCMBuffer(copying: buffer))
        }
        audioEngine.prepare()
        try audioEngine.start()
        phase = .listening
        defer {
            inputNode.removeTap(onBus: 0)
            audioEngine.stop()
            request.endAudio()
        }

        return try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask { @MainActor [weak self] in
                for try await text in results {
                    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { continue }
                    self?.transcript = trimmed
                    self?.lastTranscriptChange = .now
                }
                guard let transcript = self?.transcript, !transcript.isEmpty else {
                    throw JumpError.emptyTranscript
                }
                return transcript
            }
            group.addTask { @MainActor [weak self] in
                while !Task.isCancelled {
                    try await Task.sleep(for: .milliseconds(100))
                    guard let self, let lastChange = self.lastTranscriptChange else { continue }
                    if lastChange.duration(to: .now) >= .milliseconds(900) {
                        return self.transcript
                    }
                }
                throw CancellationError()
            }
            group.addTask {
                try await Task.sleep(for: .seconds(8))
                throw JumpError.timeout
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else { throw JumpError.emptyTranscript }
            return result
        }
    }

    private func firstMapItem(for query: String) async throws -> MKMapItem {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        let response = try await MKLocalSearch(request: request).start()
        guard let item = response.mapItems.first else { throw JumpError.noMapResult }
        return item
    }

    private func resolveDestination(from item: MKMapItem) async throws -> Destination {
        let coordinate = item.location.coordinate
        let elevation = try await elevationAt(
            latitudeDegrees: coordinate.latitude,
            longitudeDegrees: coordinate.longitude
        )
        let egm96 = CesiumBridge.egm96HeightAboveWGS84Ellipsoid(
            atLongitudeDegrees: coordinate.longitude,
            latitudeDegrees: coordinate.latitude
        )
        let groundEllipsoid = elevation + egm96
        return Destination(
            longitudeDegrees: coordinate.longitude,
            latitudeDegrees: coordinate.latitude,
            groundEllipsoidHeightMeters: groundEllipsoid
        )
    }

    private func elevationAt(latitudeDegrees: Double, longitudeDegrees: Double) async throws -> Double {
        guard let apiKey = Bundle.main.object(forInfoDictionaryKey: "GoogleMapsAPIKey") as? String,
              !apiKey.isEmpty else { throw JumpError.malformedElevation }
        var components = URLComponents(string: "https://maps.googleapis.com/maps/api/elevation/json")!
        components.queryItems = [
            URLQueryItem(name: "locations", value: "\(latitudeDegrees),\(longitudeDegrees)"),
            URLQueryItem(name: "key", value: apiKey)
        ]
        let (data, response) = try await URLSession.shared.data(from: components.url!)
        let http = response as? HTTPURLResponse
        guard http?.statusCode == 200 else { throw JumpError.elevationHTTP(http?.statusCode ?? -1) }
        let decoded = try JSONDecoder().decode(ElevationResponse.self, from: data)
        guard decoded.status == "OK" else { throw JumpError.elevationStatus(decoded.status) }
        guard let elevation = decoded.results.first?.elevation, elevation.isFinite else {
            throw JumpError.malformedElevation
        }
        return elevation
    }

    private func report(_ error: Error) {
        switch error {
        case JumpError.elevationHTTP(let status): print("Jump elevation HTTP status \(status)")
        case JumpError.elevationStatus(let status): print("Jump elevation API status \(status)")
        case JumpError.permissionDenied: print("Jump speech or microphone permission denied")
        case JumpError.unsupportedTranscriptionLocale: print("Jump speech transcriber has no supported locale")
        case JumpError.timeout: print("Jump speech timed out")
        default: print("Jump failed: \(error.localizedDescription)")
        }
    }

    private func finish() {
        operationTask?.cancel()
        operationTask = nil
        pendingDestination = nil
        transcript = ""
        phase = .idle
    }
}
