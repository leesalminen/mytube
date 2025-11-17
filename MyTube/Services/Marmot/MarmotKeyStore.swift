//
//  MarmotKeyStore.swift
//  MyTube
//
//  Created by Codex on 02/16/26.
//

import Foundation

protocol MarmotKeyStore: AnyObject {
    func fetchKeyPair(role: NostrIdentityRole) throws -> NostrKeyPair?
    func childKeyIdentifiers() throws -> [UUID]
}

extension KeychainKeyStore: MarmotKeyStore {}
