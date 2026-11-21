import CryptoKit
import Foundation

enum TOTPError: Error, Equatable {
    case invalidBase32
    case invalidDigits
}

enum TOTPService {
    private static let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")

    static func normalizedSecret(_ value: String) -> String {
        value.uppercased().filter { !$0.isWhitespace && $0 != "-" && $0 != "=" }
    }

    static func isValidSecret(_ value: String) -> Bool {
        normalizedSecret(value).count >= 16 &&
            (try? decodeBase32(value))?.isEmpty == false
    }

    static func code(
        secret: String,
        date: Date = Date(),
        period: TimeInterval = 30,
        digits: Int = 6
    ) throws -> String {
        guard (6...8).contains(digits), period > 0 else { throw TOTPError.invalidDigits }
        let keyData = try decodeBase32(secret)
        var counter = UInt64(floor(date.timeIntervalSince1970 / period)).bigEndian
        let message = withUnsafeBytes(of: &counter) { Data($0) }
        let key = SymmetricKey(data: keyData)
        let digest = Array(HMAC<Insecure.SHA1>.authenticationCode(for: message, using: key))
        let offset = Int(digest[digest.count - 1] & 0x0f)
        let binary =
            (UInt32(digest[offset] & 0x7f) << 24) |
            (UInt32(digest[offset + 1]) << 16) |
            (UInt32(digest[offset + 2]) << 8) |
            UInt32(digest[offset + 3])
        let divisor = (0..<digits).reduce(UInt32(1)) { value, _ in value * 10 }
        return String(format: "%0*u", digits, binary % divisor)
    }

    static func safeSubmissionDelay(
        date: Date = Date(),
        period: TimeInterval = 30,
        minimumRemaining: TimeInterval = 5
    ) -> TimeInterval {
        guard period > 0, minimumRemaining > 0 else { return 0 }
        let elapsed = date.timeIntervalSince1970.truncatingRemainder(dividingBy: period)
        let remaining = period - elapsed
        return remaining < minimumRemaining ? remaining : 0
    }

    private static func decodeBase32(_ value: String) throws -> Data {
        let normalized = normalizedSecret(value)
        guard !normalized.isEmpty else { throw TOTPError.invalidBase32 }

        var buffer = 0
        var bitCount = 0
        var output: [UInt8] = []
        for character in normalized {
            guard let index = alphabet.firstIndex(of: character) else {
                throw TOTPError.invalidBase32
            }
            buffer = (buffer << 5) | index
            bitCount += 5
            if bitCount >= 8 {
                bitCount -= 8
                output.append(UInt8((buffer >> bitCount) & 0xff))
                buffer &= bitCount == 0 ? 0 : (1 << bitCount) - 1
            }
        }
        guard !output.isEmpty else { throw TOTPError.invalidBase32 }
        return Data(output)
    }
}
