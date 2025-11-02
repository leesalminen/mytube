//
//  PlaybackControlButton.swift
//  MyTube
//
//  Created by Assistant on 11/27/25.
//

import SwiftUI

struct PlaybackControlButton: View {
    let systemName: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .frame(width: 56, height: 56)
        }
        .buttonStyle(KidCircleIconButtonStyle())
    }
}
