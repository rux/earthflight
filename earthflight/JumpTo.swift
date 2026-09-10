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

    /// Ends any in-flight capture/search/elevation work and returns to idle.
    /// Cancelling `operationTask` unwinds `captureTranscript`'s task group,
    /// which stops the audio tap and engine through its existing `defer`.
    /// Safe to call when already idle.
    func cancel() {
        finish()
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
        guard await Self.speechAuthorizationStatus() == .authorized else {
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

        // `SFSpeechRecognizer.queue` defaults to the app's main queue and this
        // app never changes it, so the result handler really does run on the
        // main actor, which is where Swift infers it. Only a `String` leaves it.
        let (results, resultsContinuation) = AsyncThrowingStream<String, Error>.makeStream()
        let recognitionTask = recognizer.recognitionTask(with: request) { result, error in
            if let result {
                resultsContinuation.yield(result.bestTranscription.formattedString)
                if result.isFinal {
                    resultsContinuation.finish()
                }
            }
            if let error {
                resultsContinuation.finish(throwing: error)
            }
        }

        // AVFAudio declares the tap block `@Sendable` because it runs on the
        // audio thread, so it must not touch `request`, which is main-actor
        // state like the rest of this type. The tap already copies each buffer
        // out of the read-only one it is handed, and a fresh copy sits in its
        // own isolation region and can therefore be sent. The stream is the
        // boundary: it preserves order, and the append happens on this actor.
        let (capturedAudio, capturedAudioContinuation) =
            AsyncStream<AVAudioPCMBuffer>.makeStream()
        try inputNode.installAudioTap(
            onBus: 0,
            bufferSize: 1_024,
            format: inputNode.outputFormat(forBus: 0)
        ) { buffer, _ in
            capturedAudioContinuation.yield(AVAudioPCMBuffer(copying: buffer))
        }
        // Nothing may be appended once `endAudio` has been called below, and a
        // cancelled `AsyncStream` still hands back what it had already
        // buffered, so this loop has to check cancellation itself rather than
        // trust `for await` to stop first.
        let audioAppend = Task {
            for await buffer in capturedAudio {
                guard !Task.isCancelled else { break }
                request.append(buffer)
            }
        }
        audioEngine.prepare()
        try audioEngine.start()
        phase = .listening
        defer {
            recognitionTask.cancel()
            inputNode.removeTap(onBus: 0)
            audioEngine.stop()
            // `audioAppend` is on this actor, so it cannot run inside this
            // block: by the time it is next scheduled it is already cancelled.
            capturedAudioContinuation.finish()
            audioAppend.cancel()
            request.endAudio()
        }

        // Each racer is a plain call into a main-actor method rather than a
        // `@MainActor` closure. Swift 6.4's region-isolation checker cannot
        // check a global-actor-annotated task-group child that suspends -- it
        // reports "pattern that the region-based isolation checker does not
        // understand how to check. Please file a bug" -- and this shape states
        // the same isolation without meeting that limitation, because the child
        // hops to this actor at its first await and stays there. Do not put the
        // annotation back on the closures without rechecking that diagnostic.
        return try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask { try await self.finalTranscript(from: results) }
            group.addTask { try await self.transcriptAfterSilence() }
            group.addTask {
                try await Task.sleep(for: .seconds(8))
                throw JumpError.timeout
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else { throw JumpError.emptyTranscript }
            return result
        }
    }

    /// Nonisolated on purpose. SFSpeechRecognizer.h says of this handler that
    /// "the system does not guarantee the execution of this block on your app's
    /// main dispatch queue", and it does in fact arrive on another one. Under
    /// this target's `MainActor` default isolation the handler would otherwise
    /// be inferred main-actor, and Swift 6 turns that inference into a hard
    /// check inside the bridged block, so the callback trapped the app in
    /// `_dispatch_assert_queue_fail` -- "BUG IN CLIENT OF LIBDISPATCH:
    /// Assertion failed: Block was expected to execute on queue
    /// [com.apple.main-thread]" -- the moment Jump To was pressed. Swift 5
    /// language mode tolerated the same mismatch silently; nothing about the
    /// callback changed, only whether the compiler enforces where it runs.
    ///
    /// Resuming a continuation is safe from any thread, which is the point of
    /// one, so nothing here needs the main actor. Note that the recognition
    /// result handler further down is the opposite case and is correctly
    /// main-actor: `SFSpeechRecognizer.queue` defaults to the main queue.
    nonisolated private static func speechAuthorizationStatus() async
        -> SFSpeechRecognizerAuthorizationStatus {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
    }

    /// Publishes each partial transcription for the overlay and returns the
    /// last one when the recogniser reports it is finished.
    private func finalTranscript(
        from results: AsyncThrowingStream<String, Error>
    ) async throws -> String {
        for try await text in results {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            transcript = trimmed
            lastTranscriptChange = .now
        }
        guard !transcript.isEmpty else {
            throw JumpError.emptyTranscript
        }
        return transcript
    }

    /// Ends the capture early once the transcription has stopped changing, so a
    /// finished sentence does not wait out the recogniser's own final result.
    private func transcriptAfterSilence() async throws -> String {
        while !Task.isCancelled {
            try await Task.sleep(for: .milliseconds(100))
            guard let lastChange = lastTranscriptChange else { continue }
            if lastChange.duration(to: .now) >= .milliseconds(900) {
                return transcript
            }
        }
        throw CancellationError()
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
