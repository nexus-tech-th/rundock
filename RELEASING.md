# Release RunDock

Source, release assets, the Homebrew cask and the update feed share `nexus-tech-th/rundock`.

1. Set `VERSION` and matching CLI/MCP/native fallback versions. Run focused tests and build the native release. Public builds embed `RunDockUpdateRepository=nexus-tech-th/rundock`.
2. For a normally launchable public Mac build, provide a Developer ID Application certificate and a stored notarytool profile. Use `DEVELOPER_ID_APPLICATION` and `NOTARY_PROFILE`; `NOTARIZE=1` submits/staples the app. Ad hoc development builds are not equivalent to notarized releases.
3. Create a matching `vVERSION` tag from reviewed source. The optional workflow template at `packaging/github-release-workflow.yml` builds an ARM64 DMG on macOS, checks version/feed/signature, and attaches the DMG, checksum and generated cask to a **draft** release. Enabling it under `.github/workflows/release.yml` requires a publisher with Workflows write permission; the current NEXUS organization App has repository creation/content access but not that permission. The first release uses the same scripts directly. It refuses to overwrite an existing release.
4. Verify DMG integrity, signature/notarization, release notes and public asset names. Publish only the intended verified release as the latest stable release; drafts/prereleases are not the stable update feed.
5. Run `scripts/promote-homebrew-cask.sh vVERSION` under the NEXUS Orbit role. It downloads the published DMG/checksum/cask, verifies the checksum and regenerated cask, and updates `Casks/rundock.rb`. Review and commit/push that cask with the Orbit identity. Do not modify a published asset after its cask checksum is promoted.
6. Test the public download/checksum, install the cask from the explicit repository URL, and exercise update checking against the public latest-release endpoint. The native checker must report up-to-date for the installed version and an update for an older version.

CI signing secrets (all required together): `MACOS_CERTIFICATE_BASE64`, `MACOS_CERTIFICATE_PASSWORD`, `DEVELOPER_ID_APPLICATION`, `APPLE_ID`, `APPLE_TEAM_ID`, `APPLE_APP_PASSWORD`. Keep keys/passwords in secret storage; never source control them. The workflow creates and cleans an ephemeral runner keychain. Without signing secrets it makes an explicitly ad hoc draft, not a notarized public release.

The first public release can also be built and uploaded locally using the same scripts and Orbit GitHub App identity. `scripts/package-dmg.sh --skip-build` assembles verified existing binaries. `scripts/generate-homebrew-cask.sh nexus-tech-th rundock VERSION SHA256` writes `Casks/rundock.rb` from an actual DMG digest.
