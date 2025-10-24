# Repository Guidelines

## Project Structure & Module Organization
MyTube is organized as an iPad-first SwiftUI app. Source lives in `MyTube/` with top-level files like `AppEnvironment.swift`, `PersistenceController.swift`, and `StoragePaths.swift`. Feature-specific code sits under `MyTube/Features/` (e.g., `HomeFeed/`, `Player/`, `Capture/`, `Editor/`, `ParentZone/`). Domain logic (`RankingEngine.swift`, `EditModels.swift`, `FilterPipeline.swift`) resides in `MyTube/Domain/`, and service abstractions (`VideoLibrary.swift`, `Thumbnailer.swift`, `EditRenderer.swift`, `ParentAuth.swift`) in `MyTube/Services/`. Shared UI components align under `MyTube/SharedUI/`. Media assets (stickers, LUTs, music) belong in `Resources/`. Unit and UI tests should mirror this structure under `MyTubeTests/` and `MyTubeUITests/`.

## Build, Test, and Development Commands
- `xcodebuild -scheme MyTube -destination 'platform=iOS Simulator,name=iPad (10th generation)' build`: compile the app with all targets.
- `xcodebuild test -scheme MyTube -destination 'platform=iOS Simulator,name=iPad (10th generation)'`: execute XCTest suites for unit and UI layers.
- `swift run swiftlint` (optional): verify linting before submitting changes.
- `xcrun simctl addmedia booted path/to/video.mp4`: preload sample videos for local testing.

## Coding Style & Naming Conventions
Follow standard Swift API design guidelines with 4-space indentation. Use UpperCamelCase for types, lowerCamelCase for variables/functions, and SCREAMING_SNAKE_CASE for constants that must be global. Keep feature folders SwiftUI-first: `HomeFeedView`, `HomeFeedViewModel`, `HomeFeedScene` naming is recommended. Run `swift-format --configuration .swift-format.json --recursive MyTube` when updating shared files; include the config if missing. Document non-obvious behaviors with concise comments above the relevant declarations.

## Testing Guidelines
Use `XCTest` for unit coverage and `XCUITest` for critical flows (capture→feed, play→feedback, edit→export, parent PIN). Name tests `<Feature>Tests` (e.g., `RankingEngineTests`, `ParentAuthTests`). Maintain ≥80% coverage on critical path modules (`Domain`, `Services`, `Features/HomeFeed`). When adding Core Data models, provide an in-memory stack helper under `Tests/Support/`. Run the full suite via the `xcodebuild test` command before opening a PR.

## Commit & Pull Request Guidelines
Write atomic commits using the format `area: short imperative summary` (e.g., `feed: tune ranking weights`). Include context in the body when touching persistence or security code. Pull requests must describe the change, list test evidence (command outputs or screenshots), and call out migration impacts (Core Data, storage paths). Link the relevant issue or TODO, request review from the feature owner, and add a short checklist for QA readiness.

## Security & Configuration Tips
Store sensitive tokens exclusively in the Keychain helpers under `Services/ParentAuth.swift`. Ensure local file URLs use `.completeFileProtection`. Verify no networking code or entitlements are introduced without explicit approval. When handling media imports, sanitize filenames and keep all artifacts under `Application Support/Media`, `Thumbs`, or `Edits` using per-profile subdirectories.
