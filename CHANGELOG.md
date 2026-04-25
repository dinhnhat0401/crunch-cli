# Changelog

All notable changes to `crunch-cli` are documented here. Format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.1.0] - 2026-04-25

Initial public release. Open-source compression engine behind the Crunch
Mac app.

### Added
- `crunch` CLI with `compress` (default subcommand) and `list-presets`.
- Static image compression (JPEG, PNG, HEIC, TIFF, BMP) via ImageIO.
- Animated image compression for GIF, APNG, animated WebP, animated HEIC.
- PDF compression that preserves searchable text, page structure, OCR.
- Video compression with `balanced` / `high-quality` / `tiny` /
  `email-friendly` presets via AVFoundation.
- Audio compression to AAC/M4A with metadata preservation or stripping,
  plus a `voice` preset.
- Shared preset profiles across kinds: `balanced`, `high-quality`,
  `small-file`, `tiny`.
- Output-preservation guardrails: original bytes are kept when
  recompression would grow the file, and passthrough still honors the
  caller's request.
- `CrunchCore` Swift Package library product for integration into
  third-party apps (used by the Crunch Mac app itself).
- CI lint that forbids network imports anywhere under `Sources/`.

[Unreleased]: https://github.com/dinhnhat0401/crunch-cli/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/dinhnhat0401/crunch-cli/releases/tag/v0.1.0
