import Foundation

enum ChromiumWorkerOperation: String, Codable, Equatable, Sendable {
    case check
    case rotate
}

struct ChromiumWorkerRequest: Codable, Equatable, Sendable {
    let operation: ChromiumWorkerOperation
    let email: String
    let password: String
    let currentSecret: String
    let pendingSecret: String?
    let rotationStage: RotationStage?
}

struct ChromiumWorkerProof: Codable, Equatable, Sendable {
    let passwordSubmitted: Bool
    let pendingOTPSubmitted: Bool
    let authenticatedImmediatelyAfterPendingOTP: Bool
}

struct ChromiumWorkerSuccess: Codable, Equatable, Sendable {
    let signedInEmail: String
    let planLabel: String?
    let activeUntil: String?
    let activeUntilText: String?
    let locale: String?
    let willRenew: Bool?
    let proof: ChromiumWorkerProof?
}

enum ChromiumWorkerCheckpoint: Equatable, Sendable {
    case removalStarted
    case oldMethodDisabled
    case secretCaptured(String)
    case setupConfirmed
}

enum ChromiumWorkerResult: Equatable, Sendable {
    case success(ChromiumWorkerSuccess)
    case manual(stage: RotationStage?, message: String)
    case failure(stage: RotationStage?, message: String)

    var redactedDiagnostic: String {
        switch self {
        case .success:
            return "success"
        case .manual(let stage, let message):
            return Self.diagnostic(kind: "manual", stage: stage, message: message)
        case .failure(let stage, let message):
            return Self.diagnostic(kind: "failure", stage: stage, message: message)
        }
    }

    private static func diagnostic(
        kind: String,
        stage: RotationStage?,
        message: String
    ) -> String {
        let stageText = stage.map { " \($0.rawValue)" } ?? ""
        return String("\(kind)\(stageText): \(message)".prefix(240))
    }
}

enum ChromiumWorkerEvent: Decodable, Equatable, Sendable {
    case checkpoint(id: String, checkpoint: ChromiumWorkerCheckpoint)
    case result(ChromiumWorkerResult)

    private enum CodingKeys: String, CodingKey {
        case type
        case id
        case checkpoint
        case secret
        case status
        case message
        case stage
        case signedInEmail
        case planLabel
        case activeUntil
        case activeUntilText
        case locale
        case willRenew
        case proof
    }

    private enum EventType: String, Decodable {
        case checkpoint
        case result
    }

    private enum CheckpointName: String, Decodable {
        case removalStarted
        case oldMethodDisabled
        case secretCaptured
        case setupConfirmed
    }

    private enum ResultStatus: String, Decodable {
        case success
        case manual
        case failure
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        switch try values.decode(EventType.self, forKey: .type) {
        case .checkpoint:
            let id = try values.decode(String.self, forKey: .id)
            guard !id.isEmpty else {
                throw DecodingError.dataCorruptedError(
                    forKey: .id,
                    in: values,
                    debugDescription: "Checkpoint id is empty")
            }
            let checkpoint: ChromiumWorkerCheckpoint
            switch try values.decode(CheckpointName.self, forKey: .checkpoint) {
            case .removalStarted:
                checkpoint = .removalStarted
            case .oldMethodDisabled:
                checkpoint = .oldMethodDisabled
            case .secretCaptured:
                let secret = try values.decode(String.self, forKey: .secret)
                guard !secret.isEmpty else {
                    throw DecodingError.dataCorruptedError(
                        forKey: .secret,
                        in: values,
                        debugDescription: "Captured secret is empty")
                }
                checkpoint = .secretCaptured(secret)
            case .setupConfirmed:
                checkpoint = .setupConfirmed
            }
            self = .checkpoint(id: id, checkpoint: checkpoint)

        case .result:
            switch try values.decode(ResultStatus.self, forKey: .status) {
            case .success:
                let identity = try values.decode(String.self, forKey: .signedInEmail)
                guard !identity.isEmpty else {
                    throw DecodingError.dataCorruptedError(
                        forKey: .signedInEmail,
                        in: values,
                        debugDescription: "Signed-in identity is empty")
                }
                self = .result(.success(.init(
                    signedInEmail: identity,
                    planLabel: try values.decodeIfPresent(String.self, forKey: .planLabel),
                    activeUntil: try values.decodeIfPresent(String.self, forKey: .activeUntil),
                    activeUntilText: try values.decodeIfPresent(String.self, forKey: .activeUntilText),
                    locale: try values.decodeIfPresent(String.self, forKey: .locale),
                    willRenew: try values.decodeIfPresent(Bool.self, forKey: .willRenew),
                    proof: try values.decodeIfPresent(ChromiumWorkerProof.self, forKey: .proof))))

            case .manual:
                self = .result(.manual(
                    stage: try values.decodeIfPresent(RotationStage.self, forKey: .stage),
                    message: try values.decode(String.self, forKey: .message)))

            case .failure:
                self = .result(.failure(
                    stage: try values.decodeIfPresent(RotationStage.self, forKey: .stage),
                    message: try values.decode(String.self, forKey: .message)))
            }
        }
    }
}
