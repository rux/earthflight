import AVFoundation
import Foundation
import MapKit
import Observation
import Speech

/// The `+` voice teleport: one spoken utterance, MapKit's first result for it,
/// the height of the ground there, then a destination for the scene update to
/// take. Flight is held while a jump is under way.
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

    /// What MapKit calls the place a jump went to, and the city and country it
    /// is in when MapKit knows them.
    struct Place {
        let name: String
        let context: String?
    }

    struct Destination {
        let longitudeDegrees: Double
        let latitudeDegrees: Double
        let groundEllipsoidHeightMeters: Double
        let place: Place
    }

    private struct ElevationResponse: Decodable {
        struct Result: Decodable {
            let elevation: Double
        }

        let results: [Result]
        let status: String
    }

    /// Only ever printed, so the case names are the messages.
    private enum JumpError: Error {
        case microphoneOrSpeechPermissionDenied
        case unsupportedTranscriptionLocale
        case emptyTranscript
        case noMapResult
        case missingAPIKey
        case elevationHTTP(Int)
        case elevationStatus(String)
        case malformedElevation
        case speechTimedOut
    }

    private(set) var phase: Phase = .idle
    private(set) var transcript = ""
    /// Where the last jump arrived, named on the card for a few seconds. It is
    /// not a phase, so flight carries on while it shows.
    private(set) var arrivedPlace: Place?
    private var pendingDestination: Destination?
    private var operationTask: Task<Void, Never>?
    private var arrivalDismissal: Task<Void, Never>?
    private var lastTranscriptChange: ContinuousClock.Instant?

    var isActive: Bool { phase != .idle }

    /// The card is up while a jump is under way and while it names where one
    /// arrived.
    var isCardShown: Bool { isActive || arrivedPlace != nil }

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
        hideArrival()
        transcript = ""
        lastTranscriptChange = nil
        phase = .preparingSpeech
        operationTask = Task {
            do {
                let query = try await captureTranscript()
                transcript = query
                phase = .searching
                let item = try await firstMapItem(for: query)
                phase = .resolvingElevation
                pendingDestination = try await resolveDestination(from: item, query: query)
                phase = .readyToJump
            } catch {
                if !(error is CancellationError) {
                    print("Jump To failed: \(error)")
                }
                finish()
            }
        }
    }

    /// Ends any in-flight capture/search/elevation work, returns to idle and
    /// takes the card down. Cancelling `operationTask` unwinds
    /// `captureTranscript`'s task group, which stops the audio tap and engine
    /// through its existing `defer`. Safe to call when already idle.
    func cancel() {
        finish()
        hideArrival()
    }

    /// The resolved destination, once. The scene update takes it at the moment
    /// it jumps, so that is when the arrival card starts counting.
    func takePendingDestination() -> Destination? {
        guard let destination = pendingDestination else { return nil }
        pendingDestination = nil
        finish()
        showArrival(at: destination.place)
        return destination
    }

    private func showArrival(at place: Place) {
        arrivalDismissal?.cancel()
        arrivedPlace = place
        arrivalDismissal = Task { [weak self] in
            try? await Task.sleep(for: .seconds(EarthflightTuning.jumpArrivalCardSeconds))
            // Cancelled by a new jump or the session's end, either of which
            // may already have put a newer place on the card.
            guard !Task.isCancelled else { return }
            self?.arrivedPlace = nil
        }
    }

    private func hideArrival() {
        arrivalDismissal?.cancel()
        arrivalDismissal = nil
        arrivedPlace = nil
    }

    private func captureTranscript() async throws -> String {
        guard await AVCaptureDevice.requestAccess(for: .audio),
              await Self.speechAuthorizationStatus() == .authorized else {
            throw JumpError.microphoneOrSpeechPermissionDenied
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
                throw JumpError.speechTimedOut
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
    /// [com.apple.main-thread]" -- the moment Jump To was pressed.
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

    private func resolveDestination(from item: MKMapItem, query: String) async throws -> Destination {
        let coordinate = item.location.coordinate
        // Google gives the ground's height above mean sea level; the craft
        // flies in heights above the ellipsoid. The geoid is the difference.
        let elevation = try await elevationAboveSeaLevel(
            latitudeDegrees: coordinate.latitude,
            longitudeDegrees: coordinate.longitude
        )
        let geoidHeight = CesiumBridge.egm96GeoidHeightMeters(
            longitudeDegrees: coordinate.longitude,
            latitudeDegrees: coordinate.latitude
        )
        return Destination(
            longitudeDegrees: coordinate.longitude,
            latitudeDegrees: coordinate.latitude,
            groundEllipsoidHeightMeters: elevation + geoidHeight,
            place: Place(
                name: item.name ?? query,
                context: item.addressRepresentations?.cityWithContext
            )
        )
    }

    private func elevationAboveSeaLevel(
        latitudeDegrees: Double,
        longitudeDegrees: Double
    ) async throws -> Double {
        let apiKey = Bundle.main.googleMapsAPIKey
        guard !apiKey.isEmpty else { throw JumpError.missingAPIKey }
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

    private func finish() {
        operationTask?.cancel()
        operationTask = nil
        pendingDestination = nil
        transcript = ""
        phase = .idle
    }
}
