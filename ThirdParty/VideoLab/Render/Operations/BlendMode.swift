//
//  BlendMode.swift
//  VideoLab
//
//  Created by Codex on 10/30/25.
//

import Foundation

public enum BlendMode: Int32 {
    case normal = 0
    case darken = 1
    case multiply = 2
}

public let BlendModeNormal: BlendMode = .normal
public let BlendModeDarken: BlendMode = .darken
public let BlendModeMultiply: BlendMode = .multiply
