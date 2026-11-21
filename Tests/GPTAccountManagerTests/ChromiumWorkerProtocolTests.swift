import Foundation
import Testing
@testable import GPTAccountManager

@Suite struct ChromiumWorkerProtocolTests {
    @Test func decodesSecretCheckpointWithoutLosingItsAcknowledgementID() throws {
        let data = Data(#"{"type":"checkpoint","id":"cp-1","checkpoint":"secretCaptured","secret":"JBSWY3DPEHPK3PXP"}"#.utf8)

        let event = try JSONDecoder().decode(ChromiumWorkerEvent.self, from: data)

        #expect(event == .checkpoint(
            id: "cp-1",
            checkpoint: .secretCaptured("JBSWY3DPEHPK3PXP")))
    }

    @Test func decodesOldMethodDisabledCheckpoint() throws {
        let data = Data(#"{"type":"checkpoint","id":"cp-2","checkpoint":"oldMethodDisabled"}"#.utf8)

        let event = try JSONDecoder().decode(ChromiumWorkerEvent.self, from: data)

        #expect(event == .checkpoint(
            id: "cp-2",
            checkpoint: .oldMethodDisabled))
    }

    @Test func decodesSubscriptionSuccessPayload() throws {
        let data = Data(#"{"type":"result","status":"success","signedInEmail":"user@example.com","planLabel":"plus","activeUntil":"2026-09-30T00:00:00Z","willRenew":true}"#.utf8)

        let event = try JSONDecoder().decode(ChromiumWorkerEvent.self, from: data)

        #expect(event == .result(.success(.init(
            signedInEmail: "user@example.com",
            planLabel: "plus",
            activeUntil: "2026-09-30T00:00:00Z",
            activeUntilText: nil,
            locale: nil,
            willRenew: true,
            proof: nil))))
    }

    @Test func requestEncodingContainsSecretsOnlyInStandardInputPayload() throws {
        let request = ChromiumWorkerRequest(
            operation: .rotate,
            email: "user@example.com",
            password: "private-password",
            currentSecret: "JBSWY3DPEHPK3PXP",
            pendingSecret: nil,
            rotationStage: nil)

        let encoded = try JSONEncoder().encode(request)
        let object = try #require(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any])

        #expect(object["operation"] as? String == "rotate")
        #expect(object["password"] as? String == "private-password")
        #expect(object["currentSecret"] as? String == "JBSWY3DPEHPK3PXP")
    }

    @Test func malformedSuccessWithoutIdentityIsRejected() {
        let data = Data(#"{"type":"result","status":"success","planLabel":"plus"}"#.utf8)

        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(ChromiumWorkerEvent.self, from: data)
        }
    }

    @Test func diagnosticsNeverEchoWorkerPayloadSecrets() {
        let result = ChromiumWorkerResult.failure(
            stage: .removingOldMethod,
            message: "OpenAI page changed")

        #expect(result.redactedDiagnostic == "failure removingOldMethod: OpenAI page changed")
    }
}
