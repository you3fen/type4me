import Foundation

enum ASRIdentityStore {

    private static let key = "tf_asrUID"

    static func loadOrCreateUID() -> String {
        if let existing = UserDefaults.standard.string(forKey: key),
           !existing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return existing
        }

        let newValue = "type4me-\(UUID().uuidString.lowercased())"
        UserDefaults.standard.set(newValue, forKey: key)
        return newValue
    }
}
