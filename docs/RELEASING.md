# Releasing Stale

Releases are automated. Bump the version and push to `main`:

```sh
# Version.xcconfig
MARKETING_VERSION = 1.1.0
```

The **Release** workflow builds a Release configuration, signs it with your Developer ID,
notarizes it with Apple, wraps it in `Stale-1.1.0.dmg`, and publishes a GitHub Release
tagged `v1.1.0` with auto-generated notes. If a release for that version already exists the
workflow does nothing, so other edits to the file are harmless.

## One-time setup (repository secrets)

Settings → Secrets and variables → Actions → *New repository secret*:

| Secret | Where it comes from |
|---|---|
| `APPLE_TEAM_ID` | developer.apple.com → Membership details → Team ID |
| `APPLE_ID` | The Apple ID email of your developer account |
| `APPLE_APP_SPECIFIC_PASSWORD` | appleid.apple.com → Sign-In and Security → App-Specific Passwords → generate one for "Stale notarization" |
| `DEVELOPER_ID_CERTIFICATE_P12` | See below |
| `DEVELOPER_ID_CERTIFICATE_PASSWORD` | The password you chose when exporting the `.p12` |

### Creating the Developer ID certificate

1. Xcode → Settings → Accounts → your team → **Manage Certificates…** → **+** → **Developer ID Application**.
   (Or create it at developer.apple.com → Certificates; that route needs a CSR from Keychain Access.)
2. Open **Keychain Access** → *My Certificates* → right-click *Developer ID Application: Your Name* → **Export…** → save as `.p12` with a password.
3. Base64-encode it and paste the result into the `DEVELOPER_ID_CERTIFICATE_P12` secret:

   ```sh
   base64 -i DeveloperID.p12 | pbcopy
   ```

Delete the `.p12` afterwards; the certificate stays in your Keychain.

## Building a release locally

```sh
scripts/release.sh 1.1.0          # unsigned DMG in dist/, for testing the packaging
APPLE_TEAM_ID=… APPLE_ID=… APPLE_APP_SPECIFIC_PASSWORD=… scripts/release.sh 1.1.0   # signed + notarized
```

The signed variant needs the Developer ID certificate in your login Keychain.
