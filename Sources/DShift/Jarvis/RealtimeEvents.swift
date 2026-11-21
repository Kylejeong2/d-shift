import Foundation

enum RealtimeServerEvent: Equatable {
    case audioDelta(Data)
    case speechStarted
    case speechStopped
    case responseCreated
    case functionCall(callId: String, name: String, arguments: String)
    case responseDone
    case error(String)
    case other(String)
}

struct RealtimeTool {
    let name: String
    let description: String
    let parameters: [String: Any]
}

enum RealtimeEvents {
    static let model = "gpt-realtime-2.1"
    static let sampleRate = 24_000.0

    static let defaultTurnDetection: [String: Any] = [
        "type": "server_vad", "threshold": NSDecimalNumber(string: "0.6"), "silence_duration_ms": 450,
    ]

    static var url: URL { URL(string: "wss://api.openai.com/v1/realtime?model=\(model)")! }

    static func parse(_ text: String) -> RealtimeServerEvent {
        guard let data = text.data(using: .utf8),
            let event = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
            let type = event["type"] as? String
        else { return .other("unparseable") }
        switch type {
        case "response.output_audio.delta":
            return (event["delta"] as? String).flatMap { Data(base64Encoded: $0) }.map(RealtimeServerEvent.audioDelta)
                ?? .other(type)
        case "input_audio_buffer.speech_started":
            return .speechStarted
        case "input_audio_buffer.speech_stopped":
            return .speechStopped
        case "response.created":
            return .responseCreated
        case "response.function_call_arguments.done":
            guard let callId = event["call_id"] as? String, let name = event["name"] as? String else {
                return .other(type)
            }
            return .functionCall(callId: callId, name: name, arguments: event["arguments"] as? String ?? "{}")
        case "response.done":
            return .responseDone
        case "error":
            let error = event["error"] as? [String: Any]
            return .error(error?["message"] as? String ?? "Unknown Realtime error")
        default:
            return .other(type)
        }
    }

    static func sessionUpdate(
        instructions: String, tools: [RealtimeTool], turnDetection: [String: Any] = defaultTurnDetection
    ) -> String {
        encode([
            "type": "session.update",
            "session": [
                "type": "realtime",
                "model": model,
                "instructions": instructions,
                "output_modalities": ["audio"],
                "audio": [
                    "input": [
                        "format": ["type": "audio/pcm", "rate": Int(sampleRate)],
                        "turn_detection": turnDetection,
                    ],
                    "output": [
                        "format": ["type": "audio/pcm", "rate": Int(sampleRate)],
                        "voice": "marin",
                    ],
                ],
                "tools": tools.map {
                    ["type": "function", "name": $0.name, "description": $0.description, "parameters": $0.parameters]
                },
                "tool_choice": "auto",
            ],
        ])
    }

    static func appendAudio(_ pcm: Data) -> String {
        encode(["type": "input_audio_buffer.append", "audio": pcm.base64EncodedString()])
    }

    static func functionOutput(callId: String, output: String) -> String {
        encode([
            "type": "conversation.item.create",
            "item": ["type": "function_call_output", "call_id": callId, "output": output],
        ])
    }

    static let responseCreate = #"{"type":"response.create"}"#

    static func inputImage(_ jpeg: Data) -> String {
        encode([
            "type": "conversation.item.create",
            "item": [
                "type": "message", "role": "user",
                "content": [
                    ["type": "input_image", "image_url": "data:image/jpeg;base64,\(jpeg.base64EncodedString())"]
                ],
            ],
        ])
    }

    private static func encode(_ object: [String: Any]) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }
}

struct ToolTurn {
    private var isResponseActive = false
    private var runningTools = 0
    private var hasUnsentOutput = false

    mutating func responseCreated() {
        isResponseActive = true
    }

    mutating func toolStarted() {
        runningTools += 1
    }

    mutating func toolFinished() -> Bool {
        runningTools = max(0, runningTools - 1)
        hasUnsentOutput = true
        return takeFollowUp()
    }

    mutating func responseDone() -> Bool {
        isResponseActive = false
        return takeFollowUp()
    }

    private mutating func takeFollowUp() -> Bool {
        guard hasUnsentOutput, runningTools == 0, !isResponseActive else { return false }
        hasUnsentOutput = false
        return true
    }
}

struct EchoGate {
    static let bargeInLevel: Float = 0.45
    static let sustainedChunks = 6

    private var loudChunks: [Data] = []
    private var isBargingIn = false

    mutating func pass(_ pcm: Data, level: Float, isAssistantTalking: Bool) -> [Data] {
        guard isAssistantTalking else {
            loudChunks = []
            isBargingIn = false
            return [pcm]
        }
        if isBargingIn { return [pcm] }
        guard level >= Self.bargeInLevel else {
            loudChunks = []
            return []
        }
        loudChunks.append(pcm)
        guard loudChunks.count >= Self.sustainedChunks else { return [] }
        isBargingIn = true
        defer { loudChunks = [] }
        return loudChunks
    }
}
