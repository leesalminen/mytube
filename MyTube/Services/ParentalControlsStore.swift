//
//  ParentalControlsStore.swift
//  MyTube
//
//  Created by Assistant on 02/17/26.
//

import Foundation

final class ParentalControlsStore {
    private enum Keys {
        static let requiresVideoApproval = "com.mytube.parental.requiresVideoApproval"
        static let enableContentScanning = "com.mytube.parental.enableContentScanning"
        static let autoRejectThreshold = "com.mytube.parental.autoRejectThreshold"
    }

    private let userDefaults: UserDefaults

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
    }

    var requiresVideoApproval: Bool {
        userDefaults.object(forKey: Keys.requiresVideoApproval) as? Bool ?? false
    }

    var enableContentScanning: Bool {
        userDefaults.object(forKey: Keys.enableContentScanning) as? Bool ?? true
    }

    var autoRejectThreshold: Double? {
        guard let value = userDefaults.object(forKey: Keys.autoRejectThreshold) as? Double else {
            return nil
        }
        return min(max(value, 0.0), 1.0)
    }

    func setRequiresVideoApproval(_ enabled: Bool) {
        userDefaults.set(enabled, forKey: Keys.requiresVideoApproval)
        if enabled {
            userDefaults.set(true, forKey: Keys.enableContentScanning)
        }
    }

    func setEnableContentScanning(_ enabled: Bool) {
        userDefaults.set(enabled, forKey: Keys.enableContentScanning)
    }

    func setAutoRejectThreshold(_ value: Double?) {
        guard let value else {
            userDefaults.removeObject(forKey: Keys.autoRejectThreshold)
            return
        }
        let clamped = min(max(value, 0.0), 1.0)
        userDefaults.set(clamped, forKey: Keys.autoRejectThreshold)
    }
}
