# Releasing crunch-cli

The `Release` workflow (`.github/workflows/release.yml`) runs on tag push
(`v*`). It builds a universal macOS binary, codesigns it, notarizes the
tarball, creates a GitHub release with checksums, and bumps the Homebrew
tap formula.

## Required GitHub secrets

Code signing + notarization is gated on these secrets being present —
the workflow skips signing/notarization steps if they're missing, so it
still produces an unsigned artifact on a fresh fork.

| Secret | Purpose |
| --- | --- |
| `DEVELOPER_ID_CERT_P12` | Base64 of the Developer ID Application `.p12` |
| `DEVELOPER_ID_CERT_PASSWORD` | Password for the `.p12` |
| `DEVELOPER_ID_IDENTITY` | Common name, e.g. `Developer ID Application: Nate Dinh (TEAMID)` |
| `APPLE_ID` | Apple ID email used for notarization |
| `APPLE_TEAM_ID` | Apple Developer team ID |
| `APPLE_APP_PASSWORD` | App-specific password for the Apple ID |
| `HOMEBREW_TAP_TOKEN` | PAT with `contents:write` on `dinhnhat0401/homebrew-crunch` |

Generate the base64 cert with:

```
base64 -i DeveloperID.p12 | pbcopy
```

**Credential hygiene** — these are public-repo guardrails, please follow them:

- Never commit `.p12`, `.pem`, `.cer`, `.key`, or `.env` files. `.gitignore`
  blocks the common extensions, but treat the list as a safety net, not a
  policy.
- Use an **app-specific password** for `APPLE_APP_PASSWORD`
  (appleid.apple.com → Sign-In and Security → App-Specific Passwords). Never
  use your real Apple ID password.
- `HOMEBREW_TAP_TOKEN` should be a fine-grained PAT scoped to **only**
  `dinhnhat0401/homebrew-crunch` with `Contents: read & write`. Set a short
  expiry (90 days) and rotate.
- The release workflow uses `git http.extraheader` instead of putting the
  PAT in the clone URL, so the token never lands in `.git/config` on the
  ephemeral runner.
- A cleanup step (`if: always()`) deletes the temp keychain and overwrites
  the decoded `.p12` before the runner shuts down.
- The workflow runs on `push: tags: ["v*"]` and `workflow_dispatch` only —
  not `pull_request`, so forks cannot trigger a release or read these
  secrets.

## Cutting a release

1. Update `CHANGELOG.md` — move items from `[Unreleased]` into a new
   `[X.Y.Z] - YYYY-MM-DD` section.
2. Bump the version in `Sources/crunch/CrunchCLI.swift` (the
   `version:` argument to `CommandConfiguration`).
3. Open a PR titled `Release vX.Y.Z`, merge it.
4. Tag from `trunk`:

   ```
   git tag vX.Y.Z
   git push origin vX.Y.Z
   ```

5. Watch the `Release` workflow run. It will:
   - build the universal binary
   - sign + notarize
   - create the GitHub release with `crunch-X.Y.Z-macos-universal.tar.gz`
     and a `.sha256` sidecar
   - commit a fresh `Formula/crunch.rb` to `dinhnhat0401/homebrew-crunch`

6. Smoke test:

   ```
   brew untap dinhnhat0401/crunch 2>/dev/null || true
   brew tap dinhnhat0401/crunch
   brew install crunch
   crunch --version   # → crunch 0.1.0
   ```

## Homebrew tap repo (one-time setup)

The release workflow expects an existing repo named
`dinhnhat0401/homebrew-crunch`. Create it as an empty public repo with
the default branch set to `main` (or whatever the workflow pushes to —
currently it uses `git push origin HEAD`, which works on either).

The first release run will commit `Formula/crunch.rb` into it.
