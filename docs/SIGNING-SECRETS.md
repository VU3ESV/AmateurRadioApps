# Release signing secrets (Amateur Radio Suite host)

The release workflow builds **RadioSuiteHost** — the out-of-process plugin *host* build of the
Suite (the lean `build-app.sh` build links only RadioPluginKit and declares no extension point,
so it can only show placeholders). It signs the host with Developer ID, notarizes it, and ships
`AmateurRadioSuite-<version>.{zip,dmg}` — so the released Suite can actually host third-party
ExtensionKit plugins on another Mac (see `docs/EXTENSIONKIT.md` "the gates").

This only happens when these **GitHub Actions secrets** are set on this repo
(*Settings → Secrets and variables → Actions*). Without them, the release still builds but is
**ad-hoc signed and not notarized** — fine to smoke-test on this Mac, but Gatekeeper will block
hosting third-party extensions on another Mac.

## Secrets

| Secret | What it is |
|--------|------------|
| `MACOS_CERT_P12_BASE64` | the Suite's **Developer ID Application** cert+key exported as a `.p12`, base64-encoded |
| `MACOS_CERT_PASSWORD` | the password set when exporting that `.p12` |
| `KEYCHAIN_PASSWORD` | any value — password for the throwaway CI keychain |
| `NOTARY_APPLE_ID` | Apple ID email used for notarization |
| `NOTARY_TEAM_ID` | the team id (`Y6FT52BKDA`) |
| `NOTARY_PASSWORD` | an **app-specific password** for that Apple ID ([appleid.apple.com](https://appleid.apple.com) → Sign-In & Security → App-Specific Passwords) |

> The Suite uses its **own** Developer ID cert (one per app, all under the same team). In the
> fresh CI keychain only this cert is present, so signing selects it unambiguously by name.
> Locally, `scripts/proof1-host.sh` does the same thing via a keychain notary profile
> (`ARS-Notarize`) and an auto-detected identity.

## Exporting the `.p12` (one time, on the Mac that has the cert)

Keychain Access → **login** keychain → **My Certificates** → find the Suite's
`Developer ID Application` (its private key is named e.g. `ARS Suite`) → right-click →
**Export…** → `.p12`, set a password (that's `MACOS_CERT_PASSWORD`). Then:

```sh
base64 -i Suite.p12 | pbcopy   # paste as MACOS_CERT_P12_BASE64
```

(Tip: the Suite cert's SHA-1 is `05F3B3E5A54ABFA46900372725582DE4747D45A7` if you need to pick it
among several in Keychain Access.)

## Notarization alternative (App Store Connect API key)

Instead of Apple ID + app-specific password you may prefer an ASC API key (no 2FA/expiry issues).
If you want that, say so and the workflow can switch to `--key/--key-id/--issuer` with
`NOTARY_API_KEY` / `NOTARY_API_KEY_ID` / `NOTARY_API_ISSUER` secrets.
