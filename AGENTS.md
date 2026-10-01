# Factory Switcher

Native macOS menu-bar utility. Swift, AppKit, CryptoKit and Security.framework.
No third-party runtime dependencies.

## Validation

- `swift test` uses synthetic credentials, a memory key store and temporary homes.
- `swift build -c release` builds the application.
- `bash scripts/build-app.sh` packages an ad-hoc-signed `.app` under `dist/`.
- Never test a real switch, token refresh or session rewrite in the developer's
  running Factory home. Do not stop Factory to test this app.

## Boundaries

- Authentication creation stays in the installed Droid CLI's official flow.
- Never print tokens, decrypted credentials, encryption keys or HTTP bodies.
- Store account keys in Keychain, not alongside credential files.
- Preserve unknown credential fields when updating tokens.
- Do not refresh an account that any running Droid process may be using.
- Require a stopped Factory/Droid environment before swapping login files or
  changing session metadata. Never force-kill the user's tasks.
- Back up before changes. Keep rollback and crash recovery covered by tests.
- Shared conversations may be sent to the selected account's service when
  resumed. Warn about this. Only share local sessions the user selects.
- Do not modify the Factory app bundle, security controls, host identity,
  organization policies, billing settings or remote conversation records.
