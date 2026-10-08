# Releasing TabType

TabType ships as a **signed-but-unnotarized DMG** on GitHub Releases (no Apple Developer account). This guide is for the maintainer.

## The signing identity is load-bearing

Every release **must** be signed with the same stable self-signed identity (`TabType Dev`, created by `Scripts/setup-signing.sh`). macOS ties Accessibility/Screen Recording grants to the app's code identity — if a release is ad-hoc signed or signed with a *different* cert, **every user's permissions reset** on update. `Scripts/release.sh` hard-fails on ad-hoc builds to prevent this.

**Back up the cert.** In Keychain Access, export the `TabType Dev` certificate **and its private key** as a `.p12` and store it safely. On a new machine, import the `.p12` before releasing (don't re-run `setup-signing.sh` — that would create a *different* cert and reset everyone's permissions).

## Cutting a release

```sh
./Scripts/release.sh 0.1.0
```

This bumps the version in `Info.plist`, builds, verifies the signature is stable (not ad-hoc), and produces `dist/TabType-0.1.0.dmg` with a drag-to-Applications layout. It prints the SHA-256 and next steps.

Then:

1. `git tag v0.1.0 && git push --tags`
2. Create a GitHub Release for the tag; upload `dist/TabType-0.1.0.dmg`.
3. Paste the install notes below into the release description.

## Release-notes install snippet (paste into every release)

```markdown
### Install

TabType isn't notarized (it's free and non-commercial), so macOS shows a warning the first time.

1. Download the DMG, open it, drag **TabType** to **Applications**.
2. Launch it — macOS says it "cannot be opened." Click **Done**.
3. **System Settings ▸ Privacy & Security ▸ "Open Anyway"** next to TabType, then confirm.
   - Or in Terminal: `xattr -dr com.apple.quarantine /Applications/TabType.app`
4. Grant **Accessibility** when asked (required) and **Screen Recording** (recommended: it's how TabType reads the conversation or document you're writing in).
5. First launch downloads the model (~1.1–2.5 GB) — the menu-bar icon shows progress.

Apple Silicon Mac, macOS 14+.
```

## Verify before publishing

```sh
codesign -dvv dist/TabType.app     # Authority should be "TabType Dev", NOT "Signature=adhoc"
spctl -a -vv dist/TabType.app      # will report "rejected / unnotarized" — expected, that's fine
hdiutil verify dist/TabType-<v>.dmg
```
