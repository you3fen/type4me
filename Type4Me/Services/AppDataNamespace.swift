import Foundation

/// Personal identity disables upstream updates independently of data isolation.
/// Dev builds retain the existing shared data and Keychain; UserDefaults follows
/// the installed app's bundle identifier. Personal-only previews stay isolated.
enum AppDataNamespace {
    #if TYPE4ME_PERSONAL_BUILD
    static let isPersonal = true
    #else
    static let isPersonal = false
    #endif

    #if TYPE4ME_PERSONAL_BUILD && !TYPE4ME_DEV_BUILD
    static let directoryName = "Type4Me Personal"
    static let keychainPrefix = "com.you3fen.type4me.personal"
    #else
    static let directoryName = "Type4Me"
    static let keychainPrefix = "com.type4me"
    #endif
}
