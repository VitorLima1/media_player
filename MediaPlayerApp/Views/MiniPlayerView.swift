import SwiftUI

struct MiniPlayerView: View {
    @ObservedObject var viewModel: PlayerViewModel

    var body: some View {
        VStack(spacing: 0) {
            ProgressView(
                value: viewModel.duration > 0 ? viewModel.currentTime : 0,
                total: max(viewModel.duration, 1)
            )
            .progressViewStyle(.linear)

            HStack(spacing: 14) {
                Button {
                    viewModel.togglePlayPause()
                } label: {
                    Image(systemName: viewModel.isPlaying ? "pause.fill" : "play.fill")
                        .font(.title3)
                        .frame(width: 36, height: 36)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(viewModel.isPlaying ? "Pausar" : "Tocar")

                VStack(alignment: .leading, spacing: 2) {
                    Text(viewModel.currentTrack?.displayTitle ?? "")
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)

                    Text(viewModel.currentTrack?.displaySubtitle ?? "")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                Button {
                    viewModel.next()
                } label: {
                    Image(systemName: "forward.fill")
                        .font(.title3)
                        .frame(width: 36, height: 36)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Proxima")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.bar)
        }
    }
}
