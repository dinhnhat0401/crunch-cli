# Security Policy

## Supported versions

`crunch-cli` is pre-1.0. Only the latest tagged release receives security
fixes.

| Version | Supported |
| --- | --- |
| latest `0.x.y` | Yes |
| older `0.x.y` | No |

## Reporting a vulnerability

**Please do not open a public GitHub issue for security reports.**

Use GitHub's private vulnerability disclosure:

1. Go to https://github.com/dinhnhat0401/crunch-cli/security/advisories/new
2. Fill in the report; the maintainer is notified privately.

## Scope

In scope:

- Code execution, sandbox escape, or privilege escalation triggered by a
  malicious input file processed by `crunch`.
- Information disclosure to a remote endpoint. The engine has no network
  imports (`URLSession`, `URLRequest`, `Network` — enforced by CI). A
  finding that demonstrates exfiltration is high-severity.
- Bypass of the output-preservation guardrails resulting in data loss
  (e.g. silently overwriting an input with a corrupt or larger artifact).

Out of scope:

- Denial of service from a hostile media file (we'll fix it, but it isn't
  a security issue per se).
- Issues in transitive Apple framework code (AVFoundation, PDFKit,
  ImageIO). Report those to Apple via Feedback Assistant.
- Issues in `swift-argument-parser` — report upstream.

## Response targets

- Acknowledge within **3 business days**.
- Triage + severity within **7 business days**.
- Patch released for high/critical issues within **30 days** of triage.

## Coordinated disclosure

We prefer coordinated disclosure. We'll work with you on a public
advisory + CVE assignment after the fix ships, with credit unless you
ask to remain anonymous.
