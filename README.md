# AnkiLite

[![CI](https://github.com/tamakondayo/AnkiLite/actions/workflows/ci.yml/badge.svg)](https://github.com/tamakondayo/AnkiLite/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

*[日本語版 README はこちら / Japanese version](README.ja.md)*

A free, native iOS flashcard app in SwiftUI that imports your existing Anki `.apkg` decks.

<!-- Screenshots go here. Add the three PNGs described in docs/screenshots/README.md,
     then delete this comment and uncomment the table below.

| Deck list | Study | Browser |
| --- | --- | --- |
| ![Deck list](docs/screenshots/deck-list.png) | ![Study](docs/screenshots/study.png) | ![Browser](docs/screenshots/browser.png) |

-->

## Why

The official [AnkiMobile](https://apps.apple.com/app/ankimobile-flashcards/id373493387) app for iOS costs **$24.99**. It is a one-off purchase that funds Anki's development, and it is worth supporting — but a paid app is a hard first step if you just want to try spaced repetition on your phone, or if you only need to review decks somebody else made for you.

AnkiLite is a free alternative for that case. The priority is **`.apkg` import compatibility**: decks you already have — including note types, card templates, cloze deletions, and media — should open and study correctly without a conversion step. It is a native SwiftUI app, not a web wrapper.

It is not a full Anki reimplementation, and there is no AnkiWeb sync. If you rely on sync, add-ons, or the complete feature set, buy AnkiMobile.

## Features

- **`.apkg` import** — unzips the package, reads the embedded SQLite collection (both `collection.anki21` and `collection.anki2`), and stores decks, notes, note types, and cards in the app's own database. Media files are extracted to a sandbox directory. Progress is reported during import, and re-importing an existing deck offers overwrite or merge.
- **`.apkg` export** — write decks back out to a package you can open in desktop Anki.
- **Anki card template rendering** — a `WKWebView`-based renderer supporting `{{Field}}`, `{{FrontSide}}`, `{{cloze:Field}}`, conditional sections (`{{#Field}}` / `{{^Field}}`), `[sound:...]` mapped to `<audio>`, images, note-type CSS, and Anki's `night_mode` class for dark mode.
- **Study** — front → tap to reveal → *Again / Hard / Good / Easy*, with the next interval shown on each button. Swipe gestures, per-state counts (new / learning / review), and a session summary.
- **Schedulers** — SM-2 with learning steps, ease-factor tracking (2.50 default, 1.30 floor), fuzz, and a configurable day cutoff; plus an FSRS scheduler.
- **Deck list** — hierarchical decks via `::` separators, per-state counts, swipe to delete, tap to study.
- **Card browser** — search and filter across your collection.
- **Deck stats** and **custom study** sessions.
- **Note and note type editing** — create and edit notes, manage note types and their templates.
- **Backups** and **local-first storage** — everything lives on device; there is no account and no server.
- **Dark mode**, haptics, and localized strings.

## Ads

**AnkiLite is ad-supported.** A single AdMob interstitial may appear after a completed study session, rate-limited to at most one every few minutes. There are no banners, and no ads during review itself.

This is stated up front rather than buried because it is a real trade-off: the app is free, and the ads are what make it free. If you would rather not see ads at all, [AnkiMobile](https://apps.apple.com/app/ankimobile-flashcards/id373493387) is a one-off purchase with none.

Details for anyone building or forking:

- Debug builds always use Google's official test ad unit — showing or tapping production ads from a development build counts as invalid traffic.
- The Google Mobile Ads SDK requests App Tracking Transparency at launch. Declining it does not disable the app; you get non-personalized ads.
- Ad identifiers live in `AnkiLite/Utilities/AdsManager.swift` (`AdConfig`) and `AnkiLite/Info.plist` (`GADApplicationIdentifier`). If you fork and ship this, **replace them with your own** — leaving them pointing at someone else's AdMob account is not going to end well for either of you.

## Requirements

- Xcode 16 or later
- iOS 17.0 or later
- Swift 5

Dependencies are resolved automatically by Swift Package Manager when the project is opened:

- [GRDB.swift](https://github.com/groue/GRDB.swift) — SQLite access
- [ZIPFoundation](https://github.com/weichsel/ZIPFoundation) — `.apkg` (ZIP) handling
- [Google Mobile Ads](https://github.com/googleads/swift-package-manager-google-mobile-ads) — interstitial ads

## Build

1. Clone the repository and open `AnkiLite.xcodeproj` in Xcode.
2. Wait for Xcode to resolve the Swift Package Manager dependencies.
3. Select an iOS 17+ simulator or a connected device and run (`⌘R`).
4. Run the tests with `⌘U` (the `AnkiLiteTests` target).

To run on a physical device you need to set your own signing team in the target's *Signing & Capabilities* tab.

## Project structure

```
AnkiLite/
├── App/                # Entry point and app settings
├── Models/             # Deck / Card / Note / NoteType / ReviewLog
├── Database/           # GRDB database manager and schema
├── Import/             # apkg import & export, template renderer, media
├── Scheduler/          # SM-2, FSRS, study session
├── Views/              # SwiftUI screens, WKWebView card rendering, theme
└── Utilities/          # File helpers, backups, search, haptics, ads
AnkiLiteTests/          # Renderer, scheduler, import, and database tests
```

## Roadmap

Ideas, not commitments — nothing here is scheduled:

- Broader `.apkg` compatibility coverage (unusual note types, filtered decks)
- FSRS parameter optimization from your own review history
- iPad and macOS (Catalyst) layouts
- Text-to-speech for card fields
- More UI localizations
- Real screenshots in this README

Have a deck that imports incorrectly? That is the most useful bug report you can file — see below.

## Contributing

Contributions are welcome. See [CONTRIBUTING.md](CONTRIBUTING.md) for how to file issues and open pull requests.

## License

[MIT](LICENSE) © 2026 tamakondayo

`.apkg` is Anki's export format. This project is an independent implementation and is **not affiliated with, endorsed by, or connected to** Anki, AnkiWeb, or AnkiMobile.
