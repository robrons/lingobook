---
description: Rebuild and relaunch the macOS LingoBook app
---

// turbo-all

1. Kill any running instance of LingoBook and rebuild the macOS scheme:
```
pkill -x "LingoBook" 2>/dev/null; xcodebuild -project LingoBook.xcodeproj -scheme "LingoBook (macOS)" -configuration Debug -derivedDataPath build_output build 2>&1 | tail -5
```
Run this from the project root: `/Users/robinronson/Downloads/lingobook`

2. Launch the freshly built app:
```
open build_output/Build/Products/Debug/LingoBook.app
```
Run this from the project root: `/Users/robinronson/Downloads/lingobook`
