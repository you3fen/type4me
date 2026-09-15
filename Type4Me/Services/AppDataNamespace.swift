import Foundation

/// Personal builds are opt-in at compile time. A different display name alone
/// does not isolate data or Keychain. Production defaults remain unchanged.
enum AppDataNamespace {
    #if TYPE4ME_PERSONAL_BUILD
    static let isPersonal = true
    static let directoryName = "Type4Me Personal"
    static let keychainPrefix = "com.you3fen.type4me.personal"
    #else
    static let isPersonal = false
    static let directoryName = "Type4Me"
    static let keychainPrefix = "com.type4me"
    #endif
}
