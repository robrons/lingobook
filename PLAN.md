# LingoBook Improvement Plan — Phases 0–2

Goal: fix the security/data-loss issues, then the correctness root causes, then close the UI gap with Apple Books (minimal, auto-hiding chrome; books-first library). Each task lists the files to touch, the approach, and acceptance criteria. Tasks within a phase are ordered by dependency — do them top to bottom.

**Ground rules for the executing agent:**
- Do NOT commit until Phase 0 Task 0.1 is complete (a live OpenAI key is currently in the working tree; committing it leaks it to GitHub).
- Build both schemes (`LingoBook (macOS)`, `LingoBook (iPadOS)`) after each task. All UI code is shared, so every change must be checked against both platforms' `#if os(...)` branches.
- Keep the existing MVVM structure: views stay thin, logic goes in `ReaderViewModel` or services.

---

## Phase 0 — Now (safety)

### 0.1 Remove the hardcoded OpenAI API key
**Files:** `Shared/Services/TTSService.swift:32`, `Shared/Views/Reader/ThemeSettings.swift:11`

- Change both `@AppStorage("openAIApiKey")` defaults from the literal `sk-proj-…` string to `""`.
- In `TTSService.play(...)`: if the OpenAI engine is selected but `openAIApiKey.isEmpty`, fall back to Apple TTS (don't fail silently mid-read).
- In `ThemeSettings`: when the OpenAI engine is picked and the key is empty, show a one-line hint under the SecureField ("Enter your OpenAI API key to use this engine").
- Grep the whole repo for `sk-proj` afterwards to confirm zero hits.
- **User action (not the agent's):** revoke this key in the OpenAI dashboard and create a new one. The old key must be treated as compromised.
- Note for later (Phase 2, task 2.3): key moves to Keychain; for now `@AppStorage` with empty default is acceptable.

**Accept:** no key material anywhere in the repo; OpenAI TTS with empty key falls back to Apple TTS.

### 0.2 Stop deleting the SwiftData store on migration failure
**Files:** `macOS/LingoBookMacApp.swift:6-25`, `iOS/LingoBookiPadApp.swift:6-24`

- Both app entries duplicate the same container-creation closure. Extract it into a shared helper, e.g. `Shared/Utilities/ModelContainerFactory.swift` with `static func makeContainer() -> ModelContainer`, and use it from both `@main` structs.
- On first-attempt failure: instead of `removeItem`, **rename** the store files aside (`default.store` → `default.store.backup-<ISO date>`, plus `.shm`/`.wal`) then retry with a fresh store. Log the backup path. Never delete user data.

**Accept:** a corrupted/incompatible store results in a fresh library plus backup files on disk, not silent data loss. Both apps compile using the shared factory.

---

## Phase 1 — Week 1 (correctness root causes)

### 1.1 Fix `extractParagraphs` ordering and duplication (do this BEFORE pagination — pagination consumes its output)
**File:** `Shared/Services/EPUBService.swift:180-228`

Current bug: block tags are regex-matched one tag type at a time, so headings appear after all paragraphs (wrong order) and text inside `<p>` nested in `<div>` is extracted twice.

- Replace with an `XMLParser`-based extractor (`XHTMLTextParser: NSObject, XMLParserDelegate` in the same file, matching the style of the existing `OPFParser`/`NCXParser`):
  - Walk the document in order. Treat `p, h1–h6, li, blockquote` as **emitting** blocks: accumulate `foundCharacters` while inside one; flush the trimmed text as a paragraph when it closes. Treat `div, section, body` as containers only — but if text accumulates directly inside a container and a child emitting-block starts or the container closes, flush that loose text as its own paragraph first (handles books that put bare text in `<div>`s).
  - Skip content inside `script`/`style` entirely.
  - Run each flushed block through the existing `strippingLeadingDashes()` and drop empties (preserves current behavior).
- **Entity handling:** `XMLParser` aborts on undeclared named entities (`&mdash;`, `&rsquo;`, …). Before parsing, pre-substitute a table of the ~20 common named HTML entities with their characters (`&nbsp; &amp; &lt; &gt; &quot; &apos; &mdash; &ndash; &hellip; &rsquo; &lsquo; &rdquo; &ldquo; &copy; &eacute;` etc. — keep `&amp; &lt; &gt;` numeric-safe by substituting them LAST, or convert named→numeric refs which XMLParser accepts).
- **Fallback:** if `XMLParser` fails (malformed HTML), fall back to the current regex path so no book gets worse. Keep the existing plain-text fallback as the final resort.
- Add unit-test-style verification (a small XCTest or an executable check): given HTML `"<div><h1>Title</h1><p>One</p><p>Two</p></div><p>Three</p>"`, output must be exactly `["Title", "One", "Two", "Three"]` — this fails on the current implementation both in order and duplication.

**Accept:** the test HTML above extracts in document order with no duplicates; a real EPUB chapter renders with headings in place.

### 1.2 Real text-measurement pagination + kill the inner ScrollView
**Files:** `Shared/ViewModels/ReaderViewModel.swift:191-220` (paginateContent), `Shared/Views/Reader/PageView.swift`, new `Shared/Utilities/TextMeasurement.swift`

- New helper `TextMeasurement`:
  - `static func height(of text: String, font: PlatformFont, lineSpacing: CGFloat, width: CGFloat) -> CGFloat` using `NSAttributedString.boundingRect(with: CGSize(width: width, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin, .usesFontLeading])` with an `NSMutableParagraphStyle` carrying the line spacing. `PlatformFont` = `NSFont`/`UIFont` typealias (add to `Shared/Utilities/PlatformImage.swift` or the new file).
  - Font must match rendering exactly: system serif — `NSFont/UIFont` from `systemFont(ofSize:)` descriptor `withDesign(.serif)` (see task 1.4 — PageView switches to system serif in the same PR; land 1.4's font change together with this task so measurement and rendering agree).
- Rewrite `paginateContent()`:
  - Body paragraphs: measured height at `fontSize`, line spacing 6, plus 16pt spacing between paragraphs (first paragraph on a page gets no top spacing — mirror current logic).
  - First page of a chapter: subtract the chapter-title block (measured at `fontSize + 8` + 8pt bottom padding) from that page's budget.
  - Interleaved mode: replace the magic `1.8` multiplier — measure the original sentence at `fontSize`, plus the same text measured at `fontSize * 0.9` with line spacing 4 as a proxy for the translation (FR/EN lengths are close), plus the 12pt bottom padding per pair.
  - Width: use the effective content width (see 1.4 — after the max-line-width change this is `min(availableContentWidth, maxTextWidth)`). Height: `availableContentHeight` minus the PageView vertical padding (currently 32 top + 32 bottom — account for it; today's code ignores it, which is one reason pages overflow).
- `PageView`: remove the `ScrollView`; render the VStack directly with `.frame(maxHeight: .infinity, alignment: .top)` and `.clipped()` as a safety net. Keep the translation-loading spinner branch.
- Keep `handleFontSizeChange`/`handleLayoutModeChange` flows working (they call `paginateContent()` — no signature change needed).

**Accept:** open a real novel EPUB; no page shows cut-off text at the bottom and no page is scrollable; last line of page N is followed by the next line on page N+1; interleaved mode fits both languages on every page. Resize the window — text never overflows.

### 1.3 Stable reading position (survives resize/font changes)
**Files:** `Shared/Models/Book.swift`, `Shared/ViewModels/ReaderViewModel.swift` (saveProgress:396, loadBook:131, loadChapter:151, handleSizeChange:316, handleFontSizeChange:373), `Shared/Views/Reader/ReaderView.swift` (restore call site)

- Add to `Book`: `var currentParagraphIndex: Int = 0` (default value ⇒ SwiftData lightweight migration; 0.2's backup protects the worst case). Keep `currentPageIndex` for now as a fallback for existing books.
- `saveProgress`: also store the **global paragraph index** (index into `allParagraphs`) of the first paragraph of the current page. Compute as the count of paragraphs on all preceding pages.
- Restore (`loadChapter(restoringPageIndex:)` → change to `restoringParagraphIndex:`): after pagination, find the page whose cumulative paragraph range contains the saved index. If the new field is 0 and `currentPageIndex` > 0 (pre-migration book), fall back to the old clamped page index once.
- After every repagination (`handleSizeChange`, `handleFontSizeChange`, `handleLayoutModeChange`), re-locate the page containing the previously visible first paragraph instead of clamping the page index. `handleLayoutModeChange`'s existing first-text matching (line 349-359) gets replaced by this same mechanism — but note interleaved mode re-splits paragraphs into sentences, so when the layout mode changes map via character position: remember the first ~40 chars of the first visible unit and find the new unit containing that prefix (the current code already does roughly this; keep it for the mode-change case only).

**Accept:** read to mid-chapter, resize the window drastically, bump font size twice — the same sentence stays on screen. Quit and reopen — position restores. Existing books (old schema) open without crashing.

### 1.4 Typography: real New York + max line width
**Files:** `Shared/Views/Reader/PageView.swift:37,47,67`, `Shared/ViewModels/ReaderViewModel.swift:41-47`

- Replace all `.font(.custom("NewYork-…", size:))` with `.font(.system(size:, design: .serif))` (`+ .italic()` for the interleaved translation, weight `.medium` for the chapter title). The `.custom` PostScript names silently fall back to the default font today.
- Introduce `maxTextWidth: CGFloat = 650` (constant in `ReaderViewModel`). Effective column width = `min(currentComputedWidth, maxTextWidth)`; center the text column in `PageView` (`.frame(maxWidth: maxTextWidth)` inside a centering container). Applies per column in side-by-side and to the single column interleaved.
- `availableContentWidth` must return this capped width so pagination (1.2) and rendering agree — single source of truth.

**Accept:** full-screen the Mac app: line length stays comfortable (~65–75 chars), columns centered; text is visibly serif (New York), including italics in interleaved mode.

### 1.5 Debounce resize repagination + stop translation spam
**File:** `Shared/ViewModels/ReaderViewModel.swift:316-342`

- Restructure `handleSizeChange`: on size change, show the frosted overlay immediately (as now) and store the pending size, but move `paginateContent()` + `translateCurrentPage()` **inside** the 350ms debounce task. Only the final settled size triggers repagination and one translation request.
- After repagination, skip `translateCurrentPage()` if the current page's content array is unchanged (compare to the page content the last translation was requested for — store `lastTranslatedPageContent: [String]` and compare).
- Apply the same "skip if unchanged" guard in `handleFontSizeChange`.

**Accept:** live-drag the Mac window for 3 seconds: exactly one repagination and at most one translation request fire (verify via a temporary print/breakpoint in `requestTranslation`).

### 1.6 Surface errors instead of blank pages
**Files:** `Shared/ViewModels/ReaderViewModel.swift:131-149`, `Shared/Views/Reader/ReaderView.swift`, `Shared/Views/Reader/PageView.swift`

- `loadBook`: replace `print` with `var loadError: String?` state; `ReaderView` shows a `ContentUnavailableView` ("Couldn't open this book" + error + a "Back to Library" button) when set.
- Translation failures: `translationService.error` is currently never displayed. In the translated `PageView` (and interleaved mode), when `error != nil` show a compact inline notice ("Translation unavailable — <message>") with a Retry button that calls `translateCurrentPage()`. Most common real cause: target language model not downloaded — if the message suggests that, hint at Settings → Translation.

**Accept:** import a corrupt file → readable error with a way back; simulate a translation failure (e.g. unavailable language) → notice + working retry, original text still readable.

### 1.7 Quick wins batch
**Files:** `Shared/Views/Library/LibraryView.swift`, `Shared/Views/Reader/ReaderView.swift:2-3`

- `UTType(filenameExtension: "epub")!` → `UTType.epub` (both the fileImporter and NSOpenPanel call sites).
- Remove the duplicate `import SwiftData` in `ReaderView.swift`.
- Import dedupe: in `loadBook(from:)`, before inserting, check for an existing book with the same title+author (case-insensitive); if found, show a non-error alert "Already in your library" and skip the insert.

**Accept:** importing the same EPUB twice yields one library entry + a friendly notice.

---

## Phase 2 — Week 2 (Apple Books UX)

### 2.1 Reader chrome: auto-hide, tap zones, scrubber
**Files:** `Shared/Views/Reader/ReaderView.swift`, `Shared/Views/Reader/ReaderToolbar.swift`, `Shared/Views/Reader/PageNavigator.swift` (replace), `Shared/ViewModels/ReaderViewModel.swift`

Layout change (critical): move the toolbar and bottom bar out of the `VStack` and into ZStack **overlays** on the page area, so showing/hiding chrome never changes the page geometry (otherwise every toggle would trigger repagination). The page content area becomes the full window (minus safe areas); give the text column enough top/bottom padding that chrome doesn't cover text when visible — padding is constant regardless of chrome visibility, so pagination stays stable.

- State: `isChromeVisible = true` in the view model; auto-hide after 2s of no pointer activity while reading.
  - macOS: `.onContinuousHover` on the reader — any hover movement shows chrome and restarts a hide `Task` (cancel + `Task.sleep(2s)` + hide with `.easeOut` fade). Keep chrome pinned while any popover/sheet is open (`showThemeSettings || showTOC || showSummarySheet`).
  - iPadOS: center tap toggles chrome; no timer-hide on touch (matches Books).
- Tap/click zones on the page area: leading 15% width = previous page, trailing 15% = next page, center = toggle chrome (iPad) / no-op (Mac — Mac uses hover for chrome, clicks in zones still page). Implement as three transparent `Rectangle().contentShape` regions under the text, so `textSelection` on paragraphs still wins over the zones. Keep the existing swipe gesture and arrow keys.
- Replace `PageNavigator` with a bottom overlay `ReaderScrubber`:
  - A thin track (capsule, `theme.textColor.opacity(0.15)`) with a draggable thumb; dragging jumps pages within the current chapter (compute page from drag fraction; commit on release).
  - Labels: left — book-wide progress "42%" (see 2.4 for the progress computation); right — "5 pages left in this chapter". Small (11pt), `theme.textColor.opacity(0.4)`.
  - When chrome is hidden: everything fades out except (optionally) a 2pt hairline progress line at the very bottom edge at 20% opacity — match Books' unobtrusiveness.
- `ReaderToolbar` stays functionally the same (back, TOC, mic, TTS, summary, AA) but restyle: no filled background pill on the back button; give the whole bar a subtle `.background(theme.pageColor.opacity(0.9))` + hairline divider only while visible over text.

**Accept:** open a book on Mac — chrome fades away after 2s idle, reappears on mouse move; clicking right edge pages forward; scrubber drag jumps pages; toggling chrome never reflows/repaginates the text (verify page content identical before/after). iPad: center tap toggles, edge taps page.

### 2.2 Library redesign: books-first
**Files:** `Shared/Views/Library/LibraryView.swift` (major rewrite), `Shared/Views/Library/BookCard.swift`, `Shared/Views/ContentView.swift` (toolbar lives on the NavigationStack)

- Delete `headerSection` (logo/tagline hero) and the permanent `uploadSection` dropzone.
- Toolbar (navigation toolbar, both platforms): title "Library"; `.searchable(text: $searchText)`; sort `Menu` (Recently Added / Recently Read / Title / Author); `+` import button with `⌘O` keyboard shortcut (macOS `NSOpenPanel`, iOS fileImporter — reuse existing handlers).
- Whole-window drag-and-drop stays (macOS): when `isDragging`, show a full-window overlay (dashed rounded border inset 16pt + "Drop to import" + dimmed background). No permanent drop UI.
- **Continue Reading** section at top: books with `lastReadDate != nil`, sorted descending, up to 3, horizontally laid out with larger covers (~180pt tall), title, author, and a progress label ("42%") + thin progress bar under the cover. Tapping opens the reader. Section hidden when empty.
- Grid below ("All Books"): existing adaptive grid. `BookCard` gains an always-visible progress caption on macOS too (small "42%" next to the title line; keep hover overlay behavior for title display, but progress can live in the hover overlay on Mac).
- Search filters by title/author (case/diacritic-insensitive — French titles have accents: use `localizedStandardContains`). Sorting: switch the `@Query` sort where possible; for Last Read (optional Date) sort in-memory.
- Empty library: replace the placeholder grid with a `ContentUnavailableView` ("No Books Yet", "Import an EPUB to get started", Import button).

**Accept:** window opens straight to books (or Continue Reading) with zero marketing chrome; search and all four sorts work; drag-drop still imports with the overlay affordance; empty state has a working import button.

### 2.3 Settings separation: AA popover ≠ app settings
**Files:** `Shared/Views/Reader/ThemeSettings.swift`, new `Shared/Views/SettingsView.swift`, `macOS/LingoBookMacApp.swift`, `iOS/LingoBookiPadApp.swift`, `Shared/Services/TTSService.swift`, new `Shared/Utilities/KeychainStore.swift`

- New shared `SettingsView`: TTS engine picker, read-language picker (Both/Original/English), OpenAI voice, instructions, API key field.
  - macOS: add a `Settings { SettingsView() }` scene (gets ⌘, for free).
  - iPadOS: gear button in the Library toolbar presenting `SettingsView` in a sheet.
- Move the API key from `@AppStorage` to Keychain: minimal `KeychainStore` helper (`get/set(service: "com.lingobook.openai", account: "apiKey")` via `SecItemCopyMatching`/`SecItemAdd`/`SecItemUpdate`). `SettingsView` reads/writes Keychain; `TTSService.fetchOpenAIAudio` reads it. Migrate silently: if Keychain empty and old `@AppStorage` value non-empty, move it and blank the AppStorage copy.
- Slim down the AA popover (`ThemeSettings`) to reading-only: font size stepper, theme swatches, layout picker, read-language picker (it's a reading choice — keep it here AND in settings, backed by the same AppStorage key). Remove the engine/voice/key/instructions rows.
- Fix the popover's appearance: remove the hardcoded cream `background` and `.environment(\.colorScheme, .light)` (lines 138-139) and the hardcoded beige on the font-size control (line 45); use `.regularMaterial` / theme-aware colors so it looks right in Night theme.

**Accept:** ⌘, opens Settings on Mac; gear sheet on iPad; API key survives app restart via Keychain and no longer appears in any plist (`defaults read` shows it blanked); AA popover renders correctly in Night theme.

### 2.4 Themes + book-wide progress
**Files:** `Shared/Views/Reader/BookTheme.swift`, `Shared/Views/Reader/ThemeSettings.swift`, `Shared/Models/Book.swift`, `Shared/ViewModels/ReaderViewModel.swift`

- Extend `BookTheme` with three cases (keep `calm`, `night`):
  - `paper` — pure white `#FFFFFF`, near-black text `#1A1A1A`, light scheme.
  - `sepia` — warm `#F6EEDF`-ish distinct from calm (calm is already cream; make sepia warmer/darker, e.g. bg `0.94/0.89/0.78`, text `0.30/0.22/0.12`).
  - `gray` — dim `#2A2A2E` bg, `#C8C8CC` text, dark scheme (the "reading at night but not OLED-black" option).
  - Update the swatch row in `ThemeSettings` to wrap (grid of 3×2) and derive preview colors from the theme itself; selection ring uses `Color.primary`, not hardcoded black.
- **Book-wide progress** (needed by 2.1 scrubber label and 2.2 library):
  - `Book` gains `var readingProgress: Double = 0` and `var totalChapters: Int = 0` (defaults ⇒ lightweight migration). Set `totalChapters` in `loadBook` after parsing.
  - In `saveProgress`: `readingProgress = (Double(currentChapterIndex) + pageFraction) / Double(max(1, totalChapters))` where `pageFraction = Double(currentPageIndex + 1) / Double(max(1, pages.count))`. Chapter-weighted, not exact by characters — good enough and cheap; clamp to 0…1.
  - Expose `bookProgress` on the view model for the scrubber label.

**Accept:** five themes selectable, each readable and distinct, popover legible in all of them; library and scrubber show a sane % that increases monotonically while reading forward.

---

## Suggested execution order & dependencies

```
0.1 → 0.2                      (independent, do first, then commit safely)
1.1 → 1.2 (+1.4 same PR) → 1.3 (pagination-dependent)
1.5, 1.6, 1.7                  (independent of each other; after 1.2)
2.4 (BookTheme + progress model) → 2.1 (scrubber uses progress) → 2.2 (library uses progress)
2.3                            (independent; any time in Phase 2)
```

## Verification checklist (run after Phase 1 and again after Phase 2)

1. Import a real French novel EPUB (Gutenberg's *Le Comte de Monte-Cristo* is a good stress test — deep NCX, many chapters).
2. Page through 20+ pages in both layout modes: no clipped last lines, no in-page scrolling, headings in correct positions, no duplicated paragraphs.
3. Resize the Mac window during reading: one repagination after settling, position preserved, ≤1 translation request.
4. Quit mid-chapter, relaunch: same sentence on screen.
5. Font size up/down twice: position preserved.
6. Night + Gray themes: toolbar, scrubber, AA popover, TOC sheet all legible.
7. Empty API key + OpenAI engine: TTS falls back to Apple voices.
8. `grep -r "sk-proj" .` → zero results. `defaults read` for the app domain → no key.
9. Both schemes build with no warnings introduced; run once on iPad simulator (portrait and landscape).
