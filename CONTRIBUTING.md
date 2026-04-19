# Contributing to crunch-cli

Thanks for looking. A few house rules, then how to build and run the tests.

## Non-negotiables

1. **No network imports, ever.** `URLSession`, `URLRequest`, `NWConnection`,
   `import Network` — none of these belong anywhere under `Sources/`. The
   whole positioning of Crunch ("your files never leave your Mac") hinges on
   this being structurally true, not aspirationally true.
   `scripts/forbidden-imports-lint.sh` runs in CI and blocks merges on match.
2. **Apple frameworks only in `CrunchCore`.** Acceptable: `Foundation`,
   `AVFoundation`, `PDFKit`, `ImageIO`, `CoreImage`, `CoreGraphics`,
   `UniformTypeIdentifiers`. The only third-party dependency is
   `swift-argument-parser` and it only appears in the `crunch` (CLI) target.
3. **Every public symbol gets a `///` doc comment.** Even one-liners.
4. **Public types that cross async boundaries are `Sendable`.**
5. **No UI, no paywalls, no analytics, no update checkers.** Those belong in
   the closed-source Mac app repo. See `ARCHITECTURE.md` §9 for the full
   list of things that do not go in this repo.

## Build

```
swift build
```

Release build:

```
swift build -c release
```

Universal binary for release tarballs:

```
swift build -c release --arch arm64 --arch x86_64
```

## Run

```
.build/debug/crunch photo.jpg -o photo_small.jpg --preset small-file
```

## Test

```
swift test
```

Fixtures live under `Tests/CrunchCoreTests/Fixtures/`. Keep every fixture
under 2 MB — larger fixtures go in the sibling `crunch-test-fixtures` repo.

## Lint

```
./scripts/forbidden-imports-lint.sh
```

## Regenerating the package

If you change `Package.swift`, reset SwiftPM's caches before re-opening in
Xcode:

```
rm -rf .build .swiftpm
swift package reset
swift build
```

## Style

- Server-side / CLI Swift style — no force-unwraps outside tests, prefer
  `throws` over optionals for error-returning APIs, prefer value types.
- No third-party linters required; `swift build` has to stay warning-clean.
- Prefer small files. The per-kind subdirectories under `Sources/CrunchCore/`
  (Image, Video, PDF, Audio) are a hint about how to split logic.
