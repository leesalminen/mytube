//
//  AppVersionFormatter.swift
//  MyTube
//
//  Created by Assistant on 02/16/26.
//

import Foundation

enum AppVersionFormatter {
    static var formatted: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "--"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "--"
        return "v\(version) (\(build))"
    }
}
