import AVFoundation
import os

final class VoiceSession: @unchecked Sendable {
    enum StartError: LocalizedError {
        case microphoneDenied, noAPIKey

        var errorDescription: String? {
            switch self {
            case .microphoneDenied:
                "Microphone access is off. Turn on D-Shift in System Settings > Privacy & Security > Microphone."
            case .noAPIKey: "Set an OpenAI API key from the D-Shift menu to talk to Jarvis."
            }
        }
    }

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let playbackFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: RealtimeEvents.sampleRate, channels: 1, interleaved: false)!
    private let sendFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16, sampleRate: RealtimeEvents.sampleRate, channels: 1, interleaved: true)!
    private static let echoTail: TimeInterval = 0.4

    private let playbackEnds = OSAllocatedUnfairLock(initialState: TimeInterval(0))
    private var socket: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private let onEvent: @MainActor (RealtimeServerEvent) -> Void
    private let onLevel: @MainActor (Float) -> Void

    init(onEvent: @escaping @MainActor (RealtimeServerEvent) -> Void, onLevel: @escaping @MainActor (Float) -> Void) {
        self.onEvent = onEvent
        self.onLevel = onLevel
    }

    func start(sessionUpdate: String) async throws {
        guard let apiKey = Config.value("OPENAI_API_KEY") else { throw StartError.noAPIKey }
        guard await AVCaptureDevice.requestAccess(for: .audio) else { throw StartError.microphoneDenied }
        var request = URLRequest(url: RealtimeEvents.url)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "authorization")
        let socket = URLSession.shared.webSocketTask(with: request)
        self.socket = socket
        socket.resume()
        try await socket.send(.string(sessionUpdate))
        receiveTask = Task { [onEvent, weak self] in
            var speechStoppedAt: Double?
            var isAwaitingFirstAudio = false
            var hasAnnouncedSpeaking = false
            while !Task.isCancelled {
                do {
                    guard case .string(let text) = try await socket.receive() else { continue }
                    let event = RealtimeEvents.parse(text)
                    switch event {
                    case .audioDelta(let pcm):
                        self?.play(pcm)
                        if isAwaitingFirstAudio, let speechStoppedAt {
                            isAwaitingFirstAudio = false
                            let milliseconds = Int((CACurrentMediaTime() - speechStoppedAt) * 1000)
                            Log.info("voice", "first audio \(milliseconds) ms after the user stopped talking")
                        }
                    case .speechStarted:
                        self?.interrupt()
                    case .speechStopped:
                        speechStoppedAt = CACurrentMediaTime()
                        isAwaitingFirstAudio = true
                    case .responseDone:
                        hasAnnouncedSpeaking = false
                    default:
                        break
                    }
                    if case .audioDelta = event {
                        guard !hasAnnouncedSpeaking else { continue }
                        hasAnnouncedSpeaking = true
                    }
                    await onEvent(event)
                } catch {
                    if !Task.isCancelled { await onEvent(.error(error.localizedDescription)) }
                    return
                }
            }
        }
        try startAudio(socket: socket)
    }

    func send(_ text: String) {
        socket?.send(.string(text)) { _ in }
    }

    func play(_ pcm: Data) {
        let frames = pcm.count / 2
        guard frames > 0,
            let buffer = AVAudioPCMBuffer(pcmFormat: playbackFormat, frameCapacity: AVAudioFrameCount(frames)),
            let channel = buffer.floatChannelData?[0]
        else { return }
        buffer.frameLength = AVAudioFrameCount(frames)
        pcm.withUnsafeBytes { raw in
            let samples = raw.bindMemory(to: Int16.self)
            for index in 0..<frames { channel[index] = Float(Int16(littleEndian: samples[index])) / 32768 }
        }
        let duration = Double(frames) / RealtimeEvents.sampleRate
        playbackEnds.withLock { $0 = max($0, ProcessInfo.processInfo.systemUptime) + duration }
        player.scheduleBuffer(buffer)
        if !player.isPlaying { player.play() }
    }

    func interrupt() {
        playbackEnds.withLock { $0 = 0 }
        player.stop()
        player.play()
    }

    func stop() {
        receiveTask?.cancel()
        receiveTask = nil
        engine.inputNode.removeTap(onBus: 0)
        player.stop()
        engine.stop()
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
    }

    private func startAudio(socket: URLSessionWebSocketTask) throws {
        let input = engine.inputNode
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: playbackFormat)
        let inputFormat = input.outputFormat(forBus: 0)
        guard let converter = AVAudioConverter(from: inputFormat, to: sendFormat) else { return }
        let sendFormat = sendFormat
        let playbackEnds = playbackEnds
        let gate = OSAllocatedUnfairLock(initialState: EchoGate())
        let onLevel = onLevel
        input.installTap(onBus: 0, bufferSize: 2400, format: inputFormat) { buffer, _ in
            let level = Self.level(of: buffer)
            Task { @MainActor in onLevel(level) }
            let isAssistantTalking =
                ProcessInfo.processInfo.systemUptime < playbackEnds.withLock { $0 } + Self.echoTail
            let capacity =
                AVAudioFrameCount(Double(buffer.frameLength) * sendFormat.sampleRate / inputFormat.sampleRate) + 32
            guard let converted = AVAudioPCMBuffer(pcmFormat: sendFormat, frameCapacity: capacity) else { return }
            var consumed = false
            converter.convert(to: converted, error: nil) { _, status in
                if consumed {
                    status.pointee = .noDataNow
                    return nil
                }
                consumed = true
                status.pointee = .haveData
                return buffer
            }
            guard converted.frameLength > 0, let samples = converted.int16ChannelData?[0] else { return }
            let pcm = Data(bytes: samples, count: Int(converted.frameLength) * 2)
            let chunks = gate.withLock { $0.pass(pcm, level: level, isAssistantTalking: isAssistantTalking) }
            for chunk in chunks { socket.send(.string(RealtimeEvents.appendAudio(chunk))) { _ in } }
        }
        engine.prepare()
        try engine.start()
        player.play()
        Log.info("voice", "audio engine running, input \(inputFormat)")
    }

    private static func level(of buffer: AVAudioPCMBuffer) -> Float {
        guard let channel = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return 0 }
        var sum: Float = 0
        for index in 0..<Int(buffer.frameLength) { sum += channel[index] * channel[index] }
        return min(1, (sum / Float(buffer.frameLength)).squareRoot() * 8)
    }
}
