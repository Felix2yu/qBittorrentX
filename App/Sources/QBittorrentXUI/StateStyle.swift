import QBKit
import SwiftUI

/// 状态配色。放 UI 包是因为 Color 属于 SwiftUI，核心包不能碰。
enum StateStyle {
    static func color(_ state: TorrentState) -> Color {
        switch state {
        case .downloading, .forcedDL, .metaDL, .forcedMetaDL: .blue
        case .uploading, .forcedUP: .green
        case .stalledDL, .stalledUP, .queuedDL, .queuedUP: .secondary
        case .checkingDL, .checkingUP, .checkingResumeData, .moving: .orange
        case .stoppedUP, .stoppedDL: .secondary
        case .error, .missingFiles: .red
        case .unknown: .secondary
        }
    }
}

/// 进度条 + 百分比。100% 时不再画条，只留数字——已完成的行占绝大多数，画满条纯属噪音。
struct ProgressCell: View {
    let torrent: Torrent

    var body: some View {
        if torrent.progress >= 1 {
            Text(ByteFormat.percent(1)).monospacedDigit().foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 2) {
                ProgressView(value: min(max(torrent.progress, 0), 1))
                    .progressViewStyle(.linear)
                    .tint(StateStyle.color(torrent.state))
                Text(ByteFormat.percent(torrent.progress))
                    .font(.caption).monospacedDigit().foregroundStyle(.secondary)
            }
        }
    }
}