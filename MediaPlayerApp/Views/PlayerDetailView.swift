import SwiftUI

struct PlayerDetailView: View {
    @ObservedObject var viewModel: PlayerViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var seekValue: TimeInterval = 0
    @State private var isSeeking = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 28) {
                Spacer(minLength: 12)

                Image(systemName: "music.note")
                    .font(.system(size: 64, weight: .light))
                    .foregroundStyle(.secondary)
                    .frame(width: 160, height: 160)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))

                VStack(spacing: 6) {
                    Text(viewModel.currentTrack?.displayTitle ?? "")
                        .font(.title2.weight(.semibold))
                        .multilineTextAlignment(.center)
                        .lineLimit(2)

                    Text(viewModel.currentTrack?.displaySubtitle ?? "")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                VStack(spacing: 8) {
                    Slider(
                        value: Binding(
                            get: {
                                isSeeking ? seekValue : viewModel.currentTime
                            },
                            set: { value in
                                seekValue = value
                            }
                        ),
                        in: 0...max(viewModel.duration, 1),
                        onEditingChanged: { editing in
                            isSeeking = editing
                            if !editing {
                                viewModel.seek(to: seekValue)
                            }
                        }
                    )

                    HStack {
                        Text((isSeeking ? seekValue : viewModel.currentTime).audioClockString)
                        Spacer()
                        Text(viewModel.duration.audioClockString)
                    }
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                }

                HStack(spacing: 34) {
                    Button {
                        viewModel.previous()
                    } label: {
                        Image(systemName: "backward.fill")
                            .font(.title)
                            .frame(width: 52, height: 52)
                    }
                    .accessibilityLabel("Anterior")

                    Button {
                        viewModel.togglePlayPause()
                    } label: {
                        Image(systemName: viewModel.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                            .font(.system(size: 68))
                    }
                    .accessibilityLabel(viewModel.isPlaying ? "Pausar" : "Tocar")

                    Button {
                        viewModel.next()
                    } label: {
                        Image(systemName: "forward.fill")
                            .font(.title)
                            .frame(width: 52, height: 52)
                    }
                    .accessibilityLabel("Proxima")
                }
                .buttonStyle(.plain)

                HStack(spacing: 10) {
                    Image(systemName: "speaker.fill")
                        .foregroundStyle(.secondary)

                    Slider(
                        value: Binding(
                            get: { Double(viewModel.volume) },
                            set: { viewModel.setVolume(Float($0)) }
                        ),
                        in: 0...1
                    )

                    Image(systemName: "speaker.wave.3.fill")
                        .foregroundStyle(.secondary)
                }

                Spacer()
            }
            .padding(.horizontal, 24)
            .navigationTitle("Player")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .accessibilityLabel("Fechar")
                }
            }
            .onAppear {
                seekValue = viewModel.currentTime
            }
        }
    }
}
