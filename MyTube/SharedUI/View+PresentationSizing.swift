//
//  View+PresentationSizing.swift
//  MyTube
//
//  Created by Assistant on 02/16/26.
//

import SwiftUI

extension View {
    @ViewBuilder
    func presentationSizingPageIfAvailable() -> some View {
        if #available(iOS 18.0, *) {
            presentationSizing(.page)
        } else {
            self
        }
    }
}
