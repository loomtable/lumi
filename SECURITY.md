# Security policy

## Reporting a vulnerability

Email **security@loomtable.com**. Please don't open a public issue for a security problem.

Include what you found, the steps to reproduce it, the Lumi version (select Lumi in Applications, then File › Get Info), your macOS version and your Claude Code version (`claude --version`). We'll reply within a few days, keep you posted while we fix it, and credit you in the release notes if you'd like.

## Supported versions

Fixes go into the latest release only. Please update to the [latest release](https://github.com/loomtable/lumi/releases/latest) before reporting.

| Version | Supported |
| --- | --- |
| Latest release (0.1.x) | Yes |
| Older releases | No |

## In scope

- The Lumi app and the Claude Code plugin it ships (`buddy-plugin/`).
- What Lumi reads from your screen and sends: for example, a password manager or blocked app showing up in context, a secret not being removed from a command line or address, or a screenshot kept longer than the setting allows.
- Changes or inserted text that happen without your OK.
- Lumi's local files, saved tokens and Keychain items being readable by other users or apps.
- The release DMG, its checksum and the build scripts in `Scripts/`.

## Out of scope

- Claude Code itself, Anthropic's services, and MCP servers you add: report those to their makers.
- Issues that need someone who already controls your Mac account or has physical access to an unlocked Mac.
- The macOS first-launch warning: Lumi isn't signed with an Apple Developer ID yet (see the README's Install section).
- The websites lumi.loomtable.com and loomtable.com, beyond real vulnerabilities; email those to the same address.

## Bounty

There's no bug bounty. We read every report, and we credit reporters in the release notes if they'd like.
