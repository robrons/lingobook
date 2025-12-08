# LingoBook (Native Multiplatform)

LingoBook is a native intelligent e-reader for **macOS** and **iPadOS**, designed to help you learn languages while reading. It leverages Apple's native **Translation framework** and **Apple Intelligence** (Summarization) to provide a privacy-focused, offline-capable reading experience.

![Platform](https://img.shields.io/badge/Platform-macOS%20%7C%20iPadOS-lightgrey)
![Language](https://img.shields.io/badge/Language-Swift%206.0-orange)
![License](https://img.shields.io/badge/License-MIT-blue)

## Features

- **📖 Unified Reading Experience**: A single codebase powering both Mac and iPad apps with platform-specific optimizations.
- **🗣️ Native Translation**: Instant, offline translation using Apple's new Translation API (iOS 18+ / macOS 15+).
- **🧠 Apple Intelligence Summaries**: Summarize chapters or pages on devices that support Apple Intelligence.
- **📚 EPUB Support**: Import and read standard EPUB files.
- **🎨 Apple Books-like UI**: Premium reading experience with themes (Paper, Dark, etc.), font scaling, and smooth animations.
- **☁️ Multi-Device Sync**: Progress and library synced via iCloud (SwiftData).

## Requirements

- **macOS 15.0+** (Sequoia)
- **iPadOS 18.0+**
- **Xcode 16.0+**

## Getting Started

1.  **Clone the repository**:
    ```bash
    git clone <your-repo-url>
    cd lingobook
    ```

2.  **Open the Project**:
    Double-click `LingoBook.xcodeproj` to open it in Xcode.

3.  **Run the App**:
    - Select the `LingoBook (macOS)` scheme to run on your Mac.
    - Select the `LingoBook (iPadOS)` scheme to run on a simulator or device.
    *(Note: For iPadOS/iOS devices, you will need to select your Development Team in the "Signing & Capabilities" tab).*

## Project Architecture

The project is structured to share ~95% of code between platforms:

```
/lingobook/
├── LingoBook.xcodeproj    # Unified Xcode Project
├── Shared/                # Shared Code (Models, Views, ViewModels)
│   ├── Models/            # SwiftData Models (Book)
│   ├── Services/          # Translation, Summarization, EPUB Parsing
│   ├── ViewModels/        # Logic & State (ReaderViewModel)
│   └── Views/             # SwiftUI Views (Reader, Library)
├── macOS/                 # macOS-specific code (App entry, Entitlements)
└── iOS/                   # iOS-specific code (App entry)
```

## Dependencies

- **ZIPFoundation**: For unzipping EPUB files (managed via Swift Package Manager).

## License

MIT
