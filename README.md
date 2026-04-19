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
- Animated images (GIF, APNG, animated WebP): passed through unchanged in v0.1
- PDF, video, and audio compression: stubbed in v0.1; landing in v0.2
- Four preset profiles shared across kinds: `balanced`, `high-quality`,
  `small-file`, `tiny` — plus `email-friendly` (video) and `voice` (audio)
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
