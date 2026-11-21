import Testing

@testable import DShift

struct RealtimeEventsTests {
    @Test func parsesAudioDelta() {
        let event = RealtimeEvents.parse(#"{"type":"response.output_audio.delta","delta":"AQIDBA=="}"#)
        guard case .audioDelta(let audio) = event else { Issue.record("expected audio, got \(event)"); return }
        #expect(Array(audio) == [1, 2, 3, 4])
    }

    @Test func parsesFunctionCall() {
        let event = RealtimeEvents.parse(
            #"{"type":"response.function_call_arguments.done","call_id":"c1","name":"add_note","arguments":"{\"text\":\"hi\"}"}"#
        )
        #expect(event == .functionCall(callId: "c1", name: "add_note", arguments: #"{"text":"hi"}"#))
    }

    @Test func parsesInterruptionsAndErrors() {
        #expect(RealtimeEvents.parse(#"{"type":"input_audio_buffer.speech_started"}"#) == .speechStarted)
        #expect(RealtimeEvents.parse(#"{"type":"error","error":{"message":"bad key"}}"#) == .error("bad key"))
        #expect(RealtimeEvents.parse("not json") == .other("unparseable"))
    }

    @Test func sessionUpdateUsesGASchema() {
        let text = RealtimeEvents.sessionUpdate(
            instructions: "Be brief.",
            tools: [RealtimeTool(name: "add_note", description: "Adds a note.", parameters: ["type": "object"])])
        for fragment in [
            #""type":"session.update""#, #""type":"realtime""#, #""type":"audio\/pcm""#, #""rate":24000"#,
            #""name":"add_note""#, #""type":"server_vad""#, #""threshold":0.6,"#,
        ] {
            #expect(text.contains(fragment), "missing \(fragment)")
        }
    }
}

struct ToolTurnTests {
    @Test func followsUpWhenToolFinishesBeforeResponseEnds() {
        var turn = ToolTurn()
        turn.responseCreated()
        turn.toolStarted()
        let step1 = turn.toolFinished()
        #expect(!step1)
        let step2 = turn.responseDone()
        #expect(step2)
    }

    @Test func followsUpWhenResponseEndsBeforeToolFinishes() {
        var turn = ToolTurn()
        turn.responseCreated()
        turn.toolStarted()
        let step3 = turn.responseDone()
        #expect(!step3)
        let step4 = turn.toolFinished()
        #expect(step4)
    }

    @Test func waitsForEveryToolAndNeverFollowsUpTwice() {
        var turn = ToolTurn()
        turn.responseCreated()
        turn.toolStarted()
        turn.toolStarted()
        let step5 = turn.responseDone()
        #expect(!step5)
        let step6 = turn.toolFinished()
        #expect(!step6)
        let step7 = turn.toolFinished()
        #expect(step7)
        turn.responseCreated()
        let step8 = turn.responseDone()
        #expect(!step8)
    }
}

struct EchoGateTests {
    private static let chunk = RealtimeEvents.url.absoluteString.data(using: .utf8)!

    @Test func passesEverythingWhileJarvisIsQuiet() {
        var gate = EchoGate()
        let passed = gate.pass(Self.chunk, level: 0.01, isAssistantTalking: false)
        #expect(passed.count == 1)
    }

    @Test func dropsShortLoudBurstsWhileJarvisTalks() {
        var gate = EchoGate()
        var sent = 0
        for level: Float in [0.9, 0.9, 0.1, 0.9, 0.9, 0.9, 0.1] {
            sent += gate.pass(Self.chunk, level: level, isAssistantTalking: true).count
        }
        #expect(sent == 0)
    }

    @Test func sustainedSpeechBargesInWithItsBeginning() {
        var gate = EchoGate()
        var sent: [Int] = []
        for _ in 0..<8 {
            sent.append(gate.pass(Self.chunk, level: 0.8, isAssistantTalking: true).count)
        }
        #expect(sent == [0, 0, 0, 0, 0, EchoGate.sustainedChunks, 1, 1])
    }
}
