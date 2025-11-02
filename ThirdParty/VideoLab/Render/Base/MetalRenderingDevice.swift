//
//  MetalRenderingDevice.swift
//  VideoLab
//
//  Created by Bear on 2020/8/7.
//  Copyright (c) 2020 Chocolate. All rights reserved.
//

import Foundation
import Metal

public let sharedMetalRenderingDevice = MetalRenderingDevice()

public class MetalRenderingDevice {
    public let device: MTLDevice
    public let commandQueue: MTLCommandQueue
    public let shaderLibrary: MTLLibrary
    public lazy var textureCache: TextureCache = {
        TextureCache()
    }()
    
    init() {
        guard let device = MTLCreateSystemDefaultDevice() else {
            fatalError("Could not create Metal Device")
        }
        self.device = device
        
        guard let queue = self.device.makeCommandQueue() else {
            fatalError("Could not create command queue")
        }
        self.commandQueue = queue

        let frameworkBundle: Bundle
#if SWIFT_PACKAGE
        frameworkBundle = .module
#else
        frameworkBundle = Bundle(for: MetalRenderingDevice.self)
#endif

        do {
            shaderLibrary = try device.makeDefaultLibrary(bundle: frameworkBundle)
        } catch {
            if let metallibURL = frameworkBundle.url(forResource: "default", withExtension: "metallib")
                ?? frameworkBundle.url(forResource: "VideoLab", withExtension: "metallib") {
                do {
                    shaderLibrary = try device.makeLibrary(URL: metallibURL)
                } catch {
                    fatalError("Could not load Metal library from \(metallibURL)")
                }
            } else if let fallback = try? device.makeDefaultLibrary() {
                shaderLibrary = fallback
            } else {
                fatalError("Could not locate Metal library resources in bundle \(frameworkBundle)")
            }
        }
    }
}
