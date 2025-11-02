//
//  SafetyConfigurationStore.swift
//  MyTube
//
//  Created by Assistant on 02/15/26.
//

import Foundation

final class SafetyConfigurationStore {
    private enum Keys {
        static let moderatorKey = "com.mytube.safety.moderatorKey"
        static let moderatorKeyFetchedAt = "com.mytube.safety.moderatorKeyFetchedAt"
    }

    private let userDefaults: UserDefaults

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
    }

    func moderatorPublicKey() -> String? {
        userDefaults.string(forKey: Keys.moderatorKey)
    }

    func moderatorKeyFetchedAt() -> Date? {
        guard let interval = userDefaults.object(forKey: Keys.moderatorKeyFetchedAt) as? TimeInterval else {
            return nil
        }
        return Date(timeIntervalSince1970: interval)
    }

    func saveModeratorPublicKey(_ key: String, fetchedAt: Date = Date()) {
        userDefaults.set(key, forKey: Keys.moderatorKey)
        userDefaults.set(fetchedAt.timeIntervalSince1970, forKey: Keys.moderatorKeyFetchedAt)
    }

    func clearModeratorKey() {
        userDefaults.removeObject(forKey: Keys.moderatorKey)
        userDefaults.removeObject(forKey: Keys.moderatorKeyFetchedAt)
    }
}
