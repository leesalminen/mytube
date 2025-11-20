//
//  GroupNameFormatter.swift
//  MyTube
//
//  Created by Assistant on 12/03/26.
//

import Foundation
import MDKBindings

struct GroupNameFormatter {
    static func friendlyGroupName(
        localParentKey: String?,
        remoteParentKey: String?,
        childName: String,
        parentProfileStore: ParentProfileStore
    ) -> String {
        let localName = parentDisplayName(for: localParentKey, store: parentProfileStore) ?? "Me"

        if let remoteKey = remoteParentKey {
            if let remoteName = parentDisplayName(for: remoteKey, store: parentProfileStore) {
                return "\(localName) & \(remoteName)'s Family"
            }
            let fallback = parentKeyLabel(remoteKey)
            return "\(localName) & \(fallback)'s Family"
        }

        // No remote parent yet (solo group) – include child name to avoid generic labels
        return "\(localName) & \(childName)'s Family"
    }

    static func friendlyGroupName(
        group: Group,
        members: [String],
        localParentKey: String?,
        parentProfileStore: ParentProfileStore
    ) -> String {
        let localCanonical = canonicalParentKey(localParentKey)
        let localName = parentDisplayName(for: localCanonical, store: parentProfileStore) ?? "My Family"

        var remoteNames: [String] = []
        var remoteFallbacks: [String] = []

        for member in members {
            let canonical = canonicalParentKey(member)
            if let localCanonical, canonical == localCanonical { continue }

            if let name = parentDisplayName(for: canonical, store: parentProfileStore) {
                remoteNames.append(name)
            } else {
                remoteFallbacks.append(parentKeyLabel(canonical ?? member))
            }
        }

        if remoteNames.isEmpty {
            remoteNames = remoteFallbacks
        }

        if !remoteNames.isEmpty {
            let combined = remoteNames.joined(separator: " & ")
            return "\(localName) & \(combined)'s Family"
        }

        let raw = group.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !raw.isEmpty {
            if raw.contains("Friend's Family"), let fallback = remoteFallbacks.first {
                return "\(localName) & \(fallback)'s Family"
            }
            return raw
        }

        return "\(localName)'s Family"
    }

    static func parentDisplayName(for key: String?, store: ParentProfileStore) -> String? {
        guard let canonical = canonicalParentKey(key) else { return nil }
        guard let profile = try? store.profile(for: canonical) else { return nil }
        let candidate = (profile.displayName ?? profile.name)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (candidate?.isEmpty == false) ? candidate : nil
    }

    static func canonicalParentKey(_ value: String?) -> String? {
        guard let value else { return nil }
        if let parsed = ParentIdentityKey(string: value) {
            return parsed.hex.lowercased()
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return trimmed.lowercased()
    }

    static func parentKeyLabel(_ key: String) -> String {
        if let parsed = ParentIdentityKey(string: key) {
            return shortLabel(parsed.displayValue)
        }
        return shortLabel(key)
    }

    static func shortLabel(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 8 else { return trimmed }
        let prefix = trimmed.prefix(6)
        let suffix = trimmed.suffix(4)
        return "\(prefix)…\(suffix)"
    }
}
