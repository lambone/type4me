import Foundation
import os

/// ASR client that connects to the local SenseVoice Python server via WebSocket.
actor SenseVoiceWSClient: SpeechRecognizer {

    private let logger = Logger(subsystem: "com.type4me.asr", category: "SenseVoiceWS")

    private var webSocketTask: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var eventContinuation: AsyncStream<RecognitionEvent>.Continuation?
    private var _events: AsyncStream<RecognitionEvent>?

    /// Running text from the server (latest partial or final).
    private var currentText: String = ""
    private var confirmedSegments: [String] = []

    var events: AsyncStream<RecognitionEvent> {
        if let existing = _events { return existing }
        let (stream, continuation) = AsyncStream<RecognitionEvent>.makeStream()
        self.eventContinuation = continuation
        self._events = stream
        return stream
    }

    // MARK: - Connect

    func connect(config: any ASRProviderConfig, options: ASRRequestOptions) async throws {
        // Fresh event stream
        let (stream, continuation) = AsyncStream<RecognitionEvent>.makeStream()
        self.eventContinuation = continuation
        self._events = stream
        currentText = ""
        confirmedSegments = []

        // Ensure server is running (may still be loading model from app launch)
        let mgr = SenseVoiceServerManager.shared
        let running = await mgr.isRunning
        if !running {
            try await mgr.start()
        }

        // Wait for server to become healthy (model loading can take ~10s)
        var healthy = false
        for _ in 0..<30 {
            if await mgr.isHealthy() { healthy = true; break }
            try await Task.sleep(for: .seconds(1))
        }
        guard healthy else {
            throw SenseVoiceWSError.serverNotHealthy
        }

        guard let url = await mgr.serverWSURL else {
            throw SenseVoiceWSError.serverNotRunning
        }

        let session = URLSession(configuration: .default)
        let task = session.webSocketTask(with: url)
        task.resume()
        self.webSocketTask = task

        startReceiveLoop()
        eventContinuation?.yield(.ready)
        logger.info("SenseVoiceWS connected to \(url)")
    }

    // MARK: - Send Audio

    func sendAudio(_ data: Data) async throws {
        guard let task = webSocketTask else { return }
        try await task.send(.data(data))
    }

    // MARK: - End Audio

    func endAudio() async throws {
        guard let task = webSocketTask else { return }
        // Empty data signals end of audio
        try await task.send(.data(Data()))
        logger.info("SenseVoiceWS sent end-of-audio signal")
    }

    // MARK: - Disconnect

    func disconnect() async {
        receiveTask?.cancel()
        receiveTask = nil
        webSocketTask?.cancel(with: .normalClosure, reason: nil)
        webSocketTask = nil
        eventContinuation?.finish()
        eventContinuation = nil
        _events = nil
        logger.info("SenseVoiceWS disconnected")
    }

    // MARK: - Receive Loop

    private func startReceiveLoop() {
        receiveTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                do {
                    guard let task = await self.webSocketTask else { break }
                    let message = try await task.receive()
                    await self.handleMessage(message)
                } catch {
                    if !Task.isCancelled {
                        await self.logger.info("SenseVoiceWS receive loop ended: \(error)")
                        await self.eventContinuation?.yield(.completed)
                    }
                    break
                }
            }
            await self.eventContinuation?.finish()
        }
    }

    private func handleMessage(_ message: URLSessionWebSocketTask.Message) {
        switch message {
        case .string(let text):
            guard let data = text.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = json["type"] as? String
            else { return }

            switch type {
            case "transcript":
                let recognizedText = json["text"] as? String ?? ""
                let isFinal = json["is_final"] as? Bool ?? false

                if isFinal {
                    if !recognizedText.isEmpty {
                        confirmedSegments.append(recognizedText)
                    }
                    currentText = ""
                } else {
                    currentText = recognizedText
                }

                let composedText = (confirmedSegments + (currentText.isEmpty ? [] : [currentText])).joined()

                let transcript = RecognitionTranscript(
                    confirmedSegments: confirmedSegments,
                    partialText: isFinal ? "" : currentText,
                    authoritativeText: isFinal ? composedText : "",
                    isFinal: isFinal
                )
                eventContinuation?.yield(.transcript(transcript))

                DebugFileLogger.log("SenseVoiceWS: confirmed=\(confirmedSegments.count) partial=\(currentText.count) composed=\(composedText.count) isFinal=\(isFinal)")

            case "completed":
                eventContinuation?.yield(.completed)
                logger.info("SenseVoiceWS: server signaled completion")

            case "error":
                let msg = json["message"] as? String ?? "Unknown server error"
                logger.error("SenseVoiceWS server error: \(msg)")
                eventContinuation?.yield(.error(NSError(
                    domain: "SenseVoice", code: -1,
                    userInfo: [NSLocalizedDescriptionKey: msg]
                )))

            default:
                break
            }

        case .data:
            // We don't expect binary from server
            break

        @unknown default:
            break
        }
    }
}

// MARK: - Errors

enum SenseVoiceWSError: Error, LocalizedError {
    case serverNotRunning
    case serverNotHealthy

    var errorDescription: String? {
        switch self {
        case .serverNotRunning:
            return L("SenseVoice 服务未启动", "SenseVoice server not running")
        case .serverNotHealthy:
            return L("SenseVoice 服务未就绪", "SenseVoice server not ready")
        }
    }
}
