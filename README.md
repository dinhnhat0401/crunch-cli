# crunch-cli

[![CI](https://github.com/dinhnhat0401/crunch-cli/actions/workflows/ci.yml/badge.svg)](https://github.com/dinhnhat0401/crunch-cli/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](./LICENSE)
[![macOS 14+](https://img.shields.io/badge/macOS-14%2B-black.svg)](https://www.apple.com/macos/)
[![Swift 5.10+](https://img.shields.io/badge/Swift-5.10%2B-orange.svg)](https://swift.org)
[![SwiftPM compatible](https://img.shields.io/badge/SwiftPM-compatible-brightgreen.svg)](https://swift.org/package-manager/)

Compress video, image, PDF, and audio files on your Mac. All processing stays
on-device — no uploads, no network, no third-party binaries. `crunch-cli` is
the open-source compression engine behind the Crunch Mac app.

## Install

### Homebrew (recommended, once `v0.1.0` is tagged)

```
brew install dinhnhat0401/crunch/crunch
```

### From source

```
git clone https://github.com/dinhnhat0401/crunch-cli
cd crunch-cli
swift build -c release
.build/release/crunch --help
```

### As a Swift Package (`CrunchCore` library)

Add to your `Package.swift`:

```swift
.package(url: "https://github.com/dinhnhat0401/crunch-cli", from: "0.1.0"),
```

Then depend on the `CrunchCore` product:

```swift
.target(name: "YourApp", dependencies: [
    .product(name: "CrunchCore", package: "crunch-cli"),
]),
```

In Xcode: `File` → `Add Package Dependencies…` → paste the repo URL and
select the `CrunchCore` library product.

## Quick start

```
crunch photo.jpg -o photo_small.jpg --preset small-file
```

## Features

- Static image compression (JPEG, PNG, HEIC, TIFF, BMP) via ImageIO
- Animated image compression for GIF, APNG, animated WebP, and animated HEIC
- PDF compression that preserves searchable text, page structure, and OCR text
- Video compression with balanced / high-quality / tiny / email-friendly presets
- Audio compression to AAC/M4A with metadata preservation or stripping
- Four preset profiles shared across kinds: `balanced`, `high-quality`,
  `small-file`, `tiny` — plus `email-friendly` (video) and `voice` (audio)
- Output-preservation guardrails so Crunch keeps the original bytes when
  recompression would make a file larger and passthrough still honors the request
- No third-party dependencies in the engine — only Apple frameworks
  (AVFoundation, PDFKit, ImageIO, CoreImage, CoreGraphics)
- No network imports anywhere in `Sources/`; enforced by a CI lint

## Documentation

Run `crunch --help` and `crunch list-presets` for usage. A standalone user
guide is planned for a later release.

## Contributing

See [CONTRIBUTING.md](./CONTRIBUTING.md). Security issues: see
[SECURITY.md](./SECURITY.md).

The headline rule: no network imports, ever. CI enforces it.

## License

MIT. See [LICENSE](./LICENSE).
