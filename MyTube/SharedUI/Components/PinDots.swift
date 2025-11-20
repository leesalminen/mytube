//
//  PinDots.swift
//  MyTube
//
//  Created by Assistant on 11/20/25.
//

import SwiftUI

struct PinDots: View {
    let pinLength: Int
    var maxDigits: Int = 4

    var body: some View {
        HStack(spacing: 12) {
            ForEach(0..<maxDigits, id: \.self) { index in
                Circle()
                    .strokeBorder(Color.secondary.opacity(0.3), lineWidth: 1)
                    .background(
                        Circle()
                            .fill(index < pinLength ? Color.primary : Color.clear)
                            .opacity(index < pinLength ? 0.8 : 0)
                    )
                    .frame(width: 18, height: 18)
            }
        }
    }
}

