import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @StateObject private var viewModel = PlayerViewModel()
    @State private var isShowingFileImporter = false
    @State private var isShowingFolderImporter = false
    @State private var isShowingPlayer = false

    var body: some View {
        NavigationStack {
            List {
                if viewModel.tracks.isEmpty {
                    ContentUnavailableView(
                        "Sem musicas",
                        systemImage: "music.note",
                        description: Text("Importe arquivos MP3, WAV, FLAC ou M4A.")
                    )
                    .listRowBackground(Color.clear)
                } else {
                    ForEach(viewModel.tracks) { track in
                        Button {
                            viewModel.play(track)
                        } label: {
                            TrackRowView(
                                track: track,
                                isCurrent: track == viewModel.currentTrack,
                                isPlaying: viewModel.isPlaying
                            )
                        }
                        .buttonStyle(.plain)
                    }
                    .onDelete(perform: viewModel.deleteTracks)
                }
            }
            .navigationTitle("Musicas")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button {
                            isShowingFileImporter = true
                        } label: {
                            Label("Arquivos", systemImage: "music.note.list")
                        }

                        Button {
                            isShowingFolderImporter = true
                        } label: {
                            Label("Pasta", systemImage: "folder")
                        }
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("Importar")
                }
            }
            .safeAreaInset(edge: .bottom) {
                if viewModel.currentTrack != nil {
                    MiniPlayerView(viewModel: viewModel)
                        .onTapGesture {
                            isShowingPlayer = true
                        }
                }
            }
            .overlay {
                if viewModel.isImporting {
                    ProgressView("Importando")
                        .padding(18)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                }
            }
            .task {
                await viewModel.loadLibraryIfNeeded()
            }
            .sheet(isPresented: $isShowingPlayer) {
                PlayerDetailView(viewModel: viewModel)
                    .presentationDetents([.medium, .large])
            }
            .fileImporter(
                isPresented: $isShowingFileImporter,
                allowedContentTypes: UTType.supportedAudioImportTypes,
                allowsMultipleSelection: true,
                onCompletion: handleImportResult
            )
            .fileImporter(
                isPresented: $isShowingFolderImporter,
                allowedContentTypes: [.folder],
                allowsMultipleSelection: false,
                onCompletion: handleImportResult
            )
            .alert(
                "Erro",
                isPresented: Binding(
                    get: { viewModel.errorMessage != nil },
                    set: { isPresented in
                        if !isPresented {
                            viewModel.errorMessage = nil
                        }
                    }
                )
            ) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(viewModel.errorMessage ?? "")
            }
        }
    }

    private func handleImportResult(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            viewModel.importItems(from: urls)
        case .failure(let error):
            viewModel.errorMessage = error.localizedDescription
        }
    }
}

private extension UTType {
    static var supportedAudioImportTypes: [UTType] {
        [.mp3, .mpeg4Audio, .wav, .audio, .data]
    }
}
