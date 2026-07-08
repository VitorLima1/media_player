import SwiftUI

struct TrackRowView: View {
    let track: AudioTrack
    let isCurrent: Bool
    let isPlaying: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: isCurrent ? "waveform.circle.fill" : "music.note")
                .font(.title3)
                .foregroundStyle(isCurrent ? Color.accentColor : Color.secondary)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 3) {
                Text(track.displayTitle)
                    .lineLimit(1)
                    .font(.body)

                Text(track.displaySubtitle.isEmpty ? track.sourceFileName : track.displaySubtitle)
                    .lineLimit(1)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 12)

            if isCurrent && isPlaying {
                Image(systemName: "speaker.wave.2.fill")
                    .font(.caption)
                    .foregroundStyle(Color.accentColor)
            }

            Text(track.duration.audioClockString)
                .monospacedDigit()
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }
}
