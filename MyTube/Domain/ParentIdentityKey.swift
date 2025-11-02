//
//  ParentIdentityKey.swift
//  MyTube
//
//  Created by Codex on 11/27/25.
//

import Foundation

struct ParentIdentityKey {
    let hex: String
    let bech32: String?

    var displayValue: String { bech32 ?? hex }

    init?(string: String) {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let data = Data(hexString: trimmed), data.count == 32 {
            self.hex = data.hexEncodedString()
            self.bech32 = try? NIP19.encodePublicKey(data)
            return
        }

        let lowered = trimmed.lowercased()
        if lowered.hasPrefix(NIP19Kind.npub.rawValue),
           let decoded = try? NIP19.decode(lowered),
           decoded.kind == .npub {
            self.hex = decoded.data.hexEncodedString()
            self.bech32 = try? NIP19.encodePublicKey(decoded.data)
            return
        }

        return nil
    }
}
