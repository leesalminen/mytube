//
//  RelayDirectory.swift
//  MyTube
//
//  Created by Codex on 10/28/25.
//

import Foundation

actor RelayDirectory {
    struct Endpoint: Identifiable, Codable, Hashable {
        var urlString: String
        var isEnabled: Bool

        var id: String { urlString }

        var url: URL? {
            URL(string: urlString)
        }
    }

    private enum StorageKeys {
        static let relays = "com.mytube.relays"
    }

    nonisolated(unsafe) private let userDefaults: UserDefaults
    private var endpoints: [Endpoint]

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        if let data = userDefaults.data(forKey: StorageKeys.relays),
           let decoded = try? JSONDecoder().decode([Endpoint].self, from: data) {
            endpoints = RelayDirectory.mergeDefaults(with: decoded)
        } else {
            endpoints = RelayDirectory.defaultEndpoints()
        }
        persist()
    }

    func currentRelayURLs() -> [URL] {
        endpoints
            .filter(\.isEnabled)
            .compactMap(\.url)
    }

    func allEndpoints() -> [Endpoint] {
        endpoints
    }

    func addRelay(_ url: URL, enabled: Bool = true) {
        guard !endpoints.contains(where: { $0.urlString.caseInsensitiveCompare(url.absoluteString) == .orderedSame }) else {
            return
        }
        endpoints.append(Endpoint(urlString: url.absoluteString, isEnabled: enabled))
        persist()
    }

    func removeRelay(_ url: URL) {
        endpoints.removeAll { $0.urlString.caseInsensitiveCompare(url.absoluteString) == .orderedSame }
        persist()
    }

    func setRelay(_ url: URL, enabled: Bool) {
        guard let index = endpoints.firstIndex(where: { $0.urlString.caseInsensitiveCompare(url.absoluteString) == .orderedSame }) else {
            addRelay(url, enabled: enabled)
            return
        }
        endpoints[index].isEnabled = enabled
        persist()
    }

    func replaceAll(with urls: [URL]) {
        endpoints = urls.map { Endpoint(urlString: $0.absoluteString, isEnabled: true) }
        endpoints = RelayDirectory.mergeDefaults(with: endpoints)
        persist()
    }

    func resetToDefaults() {
        endpoints = RelayDirectory.defaultEndpoints()
        persist()
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(endpoints) else {
            return
        }
        userDefaults.set(data, forKey: StorageKeys.relays)
    }

    private static func defaultEndpoints() -> [Endpoint] {
        [
            "wss://no.str.cr",
            "wss://relay.damus.io",
            "wss://relay.snort.social",
        ].map { Endpoint(urlString: $0, isEnabled: true) }
    }

    private static func mergeDefaults(with stored: [Endpoint]) -> [Endpoint] {
        var merged = stored
        let defaults = defaultEndpoints()

        for endpoint in defaults {
            if !merged.contains(where: { $0.urlString.caseInsensitiveCompare(endpoint.urlString) == .orderedSame }) {
                merged.append(endpoint)
            }
        }
        return merged
    }
}
