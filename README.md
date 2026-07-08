# Minimal Media Player iOS

Base SwiftUI/MVVM para um player local com `AVAudioPlayer`, importacao pelo Files app, playback em segundo plano e comandos da Lock Screen.

## Como usar no Xcode

1. Crie um projeto novo em **Xcode > iOS App** usando SwiftUI e Swift.
2. Adicione a pasta `MediaPlayerApp` ao target do app.
3. Em **Signing & Capabilities**, adicione **Background Modes** e marque **Audio, AirPlay, and Picture in Picture**.
4. No `Info.plist`, inclua:

```xml
<key>UIBackgroundModes</key>
<array>
    <string>audio</string>
</array>
<key>UIFileSharingEnabled</key>
<true/>
<key>LSSupportsOpeningDocumentsInPlace</key>
<true/>
```

`UIFileSharingEnabled` e `LSSupportsOpeningDocumentsInPlace` sao opcionais para o picker, mas ajudam quando voce quiser copiar arquivos via Finder/iTunes e deixar os documentos acessiveis pelo app Arquivos.

## Estrutura

- `Services/AudioPlayerManager.swift`: controla `AVAudioSession`, `AVAudioPlayer`, comandos remotos e Now Playing.
- `Services/AudioLibraryStore.swift`: importa arquivos/pastas, copia audio para `Documents/Music` e persiste o indice.
- `ViewModels/PlayerViewModel.swift`: orquestra biblioteca, playlist e estado de player para a UI.
- `Views/ContentView.swift`: lista principal, importacao, mini-player e player detalhado.

## Build no Codemagic sem .xcodeproj no Git

O arquivo `project.yml` na raiz descreve o projeto para o XcodeGen. No Codemagic, o workflow instala o XcodeGen, executa `xcodegen generate --spec project.yml` e cria `MediaPlayerApp.xcodeproj` dinamicamente antes do `xcodebuild`.

Mantenha esta relacao de caminhos:

- `project.yml`: raiz do repositorio.
- `codemagic.yaml`: raiz do repositorio.
- `MediaPlayerApp/Resources/Info.plist`: plist lido pelo target via `INFOPLIST_FILE`.
- `MediaPlayerApp/App`, `Models`, `Services`, `ViewModels`, `Views`, `Utilities`: fontes Swift mapeadas no target.

O workflow gera `build/MediaPlayerApp-unsigned.ipa` e tambem publica o `.app` em `build/DerivedData/Build/Products/Release-iphoneos/`.
