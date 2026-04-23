# crunch-cli

[![CI](https://github.com/dinhnhat0401/crunch-cli/actions/workflows/ci.yml/badge.svg)](https://github.com/dinhnhat0401/crunch-cli/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](./LICENSE)
[![macOS 14+](https://img.shields.io/badge/macOS-14%2B-black.svg)](https://www.apple.com/macos/)

Compress video, image, PDF, and audio files on your Mac. All processing stays
on-device — no uploads, no network, no third-party binaries. `crunch-cli` is
the open-source compression engine behind the Crunch Mac app.

## Install

A Homebrew tap is planned; it doesn't exist yet. In the meantime, build from
source (see below) or wait for the `v0.1.0` release.

```
# (planned, not yet published)
brew install dinhnhat0401/crunch/crunch
```

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

- `guide/` — user guide (to be published)
- [Design docs](./) — see `ARCHITECTURE-ENGINE.md` and `SYSTEM-DESIGN.md` in
  the private design repo for the full contract

## Contributing

See [CONTRIBUTING.md](./CONTRIBUTING.md).

The headline rule: no network imports, ever. CI enforces it.

## Build from source

```
git clone https://github.com/dinhnhat0401/crunch-cli
cd crunch-cli
swift build -c release
.build/release/crunch --help
```

## License

MIT. See [LICENSE](./LICENSE).
