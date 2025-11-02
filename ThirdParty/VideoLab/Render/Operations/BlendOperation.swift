//
//  BlendOperation.swift
//  VideoLab
//
//  Created by Bear on 2020/8/5.
//  Copyright © 2020 Chocolate. All rights reserved.
//

import Foundation
import Metal
import simd

public class BlendOperation: BasicOperation {
    public let requiresBackgroundTexture: Bool

    public var modelView: float4x4 = float4x4.identity() {
        didSet {
            uniformSettings["modelView"] = modelView
        }
    }
    
    public var projection: float4x4 = float4x4.identity() {
        didSet {
            uniformSettings["projection"] = projection
        }
    }
    
    public var blendMode: BlendMode = BlendModeNormal {
        didSet {
            uniformSettings["blendMode"] = blendMode.rawValue
        }
    }
    
    public var blendOpacity: Float = 1.0 {
        didSet {
            uniformSettings["blendOpacity"] = blendOpacity
        }
    }
    
    private static var supportsDestinationRead: Bool = {
        sharedMetalRenderingDevice.device.readWriteTextureSupport != .tierNone
    }()
    
    public init() {
        let supportsRead = Self.supportsDestinationRead
        self.requiresBackgroundTexture = !supportsRead
        if supportsRead {
            super.init(vertexFunctionName: "blendOperationVertex", fragmentFunctionName: "blendOperationFragment", numberOfInputs: 1)
        } else {
            super.init(vertexFunctionName: "blendOperationVertex", fragmentFunctionName: "blendOperationFallbackFragment", numberOfInputs: 2)
            enableOutputTextureRead = false
        }
        
        ({ blendMode = BlendModeNormal })()
        ({ blendOpacity = 1.0 })()
    }
}
