import CryptoKit
import Foundation

/// Deterministic segment IDs for cloud prompts.
///
/// The DeepSeek context cache matches token prefixes. Random per-capture UUIDs
/// made every repeated screen batch look different to the model even when the
/// source text was unchanged. Deriving the prompt ID from the source text keeps
/// the prompt byte-identical for identical content, so the whole request can
/// hit the cached prefix instead of only the static system message.
public enum PromptStableIdentifier {
    public static func id(for sourceText: String) -> UUID {
        var hasher = SHA256()
        hasher.update(data: Data(sourceText.utf8))
        let digest = hasher.finalize()
        var bytes = Array(digest.prefix(16))
        // RFC 4122 version 5 / SHA-256-derived UUID layout.
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        let tuple: uuid_t = (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        )
        return UUID(uuid: tuple)
    }
}
