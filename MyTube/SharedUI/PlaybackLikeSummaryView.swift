//
//  PlaybackLikeSummaryView.swift
//  MyTube
//
//  Created by Assistant on 11/27/25.
//

import SwiftUI

struct PlaybackLikeSummaryView: View {
    let likeCount: Int
    let records: [LikeRecord]

    private var displayRecords: ArraySlice<LikeRecord> {
        records.prefix(8)
    }

    private var overflowLabel: String? {
        let overflow = likeCount - displayRecords.count
        return overflow > 0 ? "+\(overflow) more" : nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(titleText)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)

            if likeCount == 0 {
                Text("Be the first to like this video!")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(displayRecords), id: \.id) { record in
                        Text(record.displayName)
                            .font(.footnote)
                            .foregroundStyle(record.isLocalUser ? .primary : .secondary)
                    }
                    if let overflowLabel {
                        Text(overflowLabel)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(.top, 4)
    }

    private var titleText: String {
        switch likeCount {
        case 0:
            return "No likes yet"
        case 1:
            return "1 Like"
        default:
            return "\(likeCount) Likes"
        }
    }
}
