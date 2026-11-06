# RunDock

Native macOS app for developers using AI coding agents. The user approved the generated three-column dark native terminal concept in this chat and requested implementation, a CLI, an AI skill, DMG and Homebrew distribution. No website UI or HTTP UI server.

## Platform
Native macOS, SwiftUI shell and AppKit terminal. Product: RunDock. Publisher: NEXUS. Bundle ID: com.nexus.rundock. CLI: rundock. Repository, release assets, Homebrew cask and update feed: nexus-tech-th/rundock.

## Purpose
Keep development services under a local process supervisor independent of the AI turn and app window. Humans and agents share status, logs and controls. Never populate the real UI with invented running services.

## Acceptance
Register and run a real command, receive terminal input/output, expose it through CLI, close/reopen GUI without losing the daemon or service, stop only the managed process group. Persist definitions and activity. Publish a verified Developer ID-signed and notarized DMG, promote its exact checksum into the same repository’s Homebrew cask, verify installation from the public URL and verify native update checks against the stable GitHub release feed. A draft release or local package alone is not public release acceptance.
