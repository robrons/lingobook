# LingoBook (Native Multiplatform)

LingoBook is a native e-reader for **macOS**, **iPadOS** and **tvOS**, designed to help you learn languages while reading. It uses Apple's Translation framework and system narration voices. Translation requires the relevant language downloads on the device.

![Platform](https://img.shields.io/badge/Platform-macOS%20%7C%20iPadOS%20%7C%20tvOS-lightgrey)
![Language](https://img.shields.io/badge/Language-Swift%206.0-orange)
![License](https://img.shields.io/badge/License-MIT-blue)

## Features

- **📖 Unified Reading Experience**: A single codebase powering both Mac and iPad apps with platform-specific optimizations.
- **🗣️ Native Translation**: Instant, offline translation using Apple's new Translation API (iOS 18+ / macOS 15+).
- **🗣️ Read Aloud**: Listen to the original text, English, or both using installed system voices.
- **📚 EPUB Support**: Import and read standard EPUB files.
- **🎨 Apple Books-like UI**: Premium reading experience with themes (Paper, Dark, etc.), font scaling, and smooth animations.
- **💾 Saved Reading Position**: Library, preferences, and progress are stored locally on each device with SwiftData. iCloud sync is not implemented.
- **👆 iPad Controls**: Tap the page to show or hide controls; use the visible previous/next arrows to turn pages. Controls stay visible until you hide them. Import EPUBs from Files or open them in LingoBook from another app.

## Requirements

- **macOS 15.0+** (Sequoia)
- **iPadOS 18.0+**
- **tvOS 18.0+** (Apple TV HD or 4K)
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
│   ├── Services/          # Translation, narration, EPUB parsing
│   ├── ViewModels/        # Logic & State (ReaderViewModel)
│   └── Views/             # SwiftUI Views (Reader, Library)
├── macOS/                 # macOS-specific code (App entry, Entitlements)
└── iOS/                   # iOS-specific code (App entry)
└── tvOS/                  # Apple TV app (library, remote-driven reader, book receiver)
```

## Installing on iPad

Choose the **LingoBook (iPadOS)** scheme, select your paired iPad, and run. The target supports iPadOS 18 and later, portrait and landscape, and resizable windows. New iPad books default to interleaved text; the AA menu also offers side-by-side reading.

Wireless installation works once Xcode can connect to the paired device. Keep the iPad unlocked and reachable from the Mac. Developer Mode and a development signing team are required. Personal-team builds expire according to their provisioning profile and need rebuilding/reinstalling; updating the same bundle preserves its app data.

```bash
xcodebuild -project LingoBook.xcodeproj -scheme 'LingoBook (iPadOS)' \
  -configuration Debug -destination 'id=<iPad-UDID>' \
  -derivedDataPath /tmp/LingoBook-iPad-build \
  -allowProvisioningUpdates -allowProvisioningDeviceRegistration build
xcrun devicectl list devices
xcrun devicectl device install app --device '<paired-device-id>' \
  /tmp/LingoBook-iPad-build/Build/Products/Debug-iphoneos/LingoBook.app
xcrun devicectl device process launch --device '<paired-device-id>' com.lingobook.ipad
```

Use the physical iPad's UDID as the build destination so automatic signing includes that device in the provisioning profile. A generic iOS build may reuse a profile registered only for another device.

The simulator can verify import, layout, and navigation, but Apple's translation service requires a physical device. No AI model dependency is linked into the iPad target; it uses ZIPFoundation for EPUB import.

## Reading on Apple TV

tvOS has no Translation framework and no file picker, so the Mac does both jobs:

1. In LingoBook on the Mac, right-click a book and choose **Send to Apple TV**.
2. The Mac translates the whole book on-device (the card shows *Translating…%*), then sends it over the local network to any Apple TV running LingoBook. If the TV app isn't open, the card says *Waiting for Apple TV* and the book goes the next time it is — as long as LingoBook is still open on the Mac.
3. On the TV, the book arrives with every translation included. Translations are saved in the book on the Mac too, so those pages open instantly and offline there as well.

Remote: left/right turn pages, Play/Pause reads aloud, click the touch surface for contents, text size, theme and layout, Back to close them.

Install with the **LingoBook (tvOS)** scheme. Pair the Apple TV with Xcode first: on the TV open Settings → Remotes and Devices → Remote App and Devices, then in Xcode open Window → Devices and Simulators and pair it with the code shown.

## Dependencies

- **ZIPFoundation**: For unzipping EPUB files (managed via Swift Package Manager).

## License

MIT
