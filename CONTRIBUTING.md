# Contributing to AnkiLite

Thanks for taking the time to help. Issues and pull requests are both welcome.

Japanese is fine for issues and PRs — 日本語で構いません。

## Before you start

Set up a local build first: see [Build](README.md#build) in the README. In short — open `AnkiLite.xcodeproj` in Xcode 16+, let Swift Package Manager resolve the dependencies, and run on an iOS 17+ simulator.

## Filing an issue

Search the existing issues first, then open a new one with:

- What you did, what you expected, and what happened instead
- iOS version and device (or simulator)
- The app version / commit you are on

**For import bugs, this is the most valuable report you can file.** Include how the deck was produced (desktop Anki version, or where you downloaded it) and, if you can share it, a minimal `.apkg` that reproduces the problem — ideally one deck with one or two notes rather than a 10,000-card collection. Please do not attach decks containing personal or copyrighted material.

## Pull requests

1. Fork the repo and branch off `main`.
2. Keep the change focused — one topic per PR. Unrelated cleanups are easier to review separately.
3. Match the surrounding code style. The project is plain SwiftUI with no linter configured.
4. Add or update tests in `AnkiLiteTests` when you change scheduling, template rendering, import, or database behaviour.
5. Run the tests (`⌘U`) and make sure they pass before opening the PR.
6. Describe what changed and why. If it is a UI change, a screenshot or short screen recording helps a lot.

Larger changes — new schedulers, storage/schema migrations, sync — are worth opening an issue to discuss before you write the code.

## Scope

AnkiLite aims to be a small, free, native iOS reader and reviewer for existing `.apkg` decks. It is not trying to reimplement all of Anki, and AnkiWeb sync is out of scope. Improvements to `.apkg` compatibility are always in scope.

## License

By contributing, you agree that your contributions are licensed under the [MIT License](LICENSE) that covers this project.
