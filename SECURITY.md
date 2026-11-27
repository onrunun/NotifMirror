# Security Policy

NotifMirror is a single-user tool that runs only on your own LAN. There is
no cloud component, no third-party telemetry, and no accounts. This policy
is short on purpose — the surface area is small.

## Reporting a vulnerability

Please **do not** open a public GitHub issue for security problems that
involve a live threat to users. Instead, open a private security advisory via:

- **GitHub → Security → "Report a vulnerability"**

You will get an acknowledgement within 7 days.

## Scope

The codebase: the wire protocol, TLS/pairing, bulk file transfer, file
browsing, clipboard sync, and both app frontends.

## Threat model

From `protocol/PROTOCOL.md`:

- **Transport security:** Both the WebSocket control channel (`wss://`) and the
  bulk HTTP/1.1 transfer data plane (`https://`) are TLS-protected with a
  self-signed RSA-2048 certificate on the Mac, SPKI-pinned on Android via the
  QR code's `fp` field. A passive sniffer on the same Wi-Fi cannot read
  clipboard text, notification bodies, or file bytes.
- **Peer authentication:** The 32-byte pre-shared `secret` (verified in
  constant time in `hello` and `Authorization: Bearer`) proves which paired
  phone may talk to the server.
- **Local storage:**
  - *macOS:* The pairing secret and TLS keypair are stored in the user-scoped
    preferences plist (`~/Library/Preferences`) rather than login Keychain
    because ad-hoc signed builds change code signature on rebuild. Rolling
    notification history (up to 500 entries) is persisted under
    `~/Library/Application Support/NotifMirror/history.json` and can be cleared
    at any time from the app. Session clipboard history is RAM-only and cleared
    on quit.
  - *Android:* The pairing payload (secret and SPKI fingerprint) is stored in
    `EncryptedSharedPreferences` backed by Android Keystore. App backups
    (`android:allowBackup="false"`) and cleartext traffic
    (`android:usesCleartextTraffic="false"`) are disabled.
  - *Diagnostic logging:* File-based debug logging is disabled in release
    builds on both platforms.
- **Out of scope:** An active attacker who already controls the phone or the
  Mac. A photographed QR is equivalent to a leaked password — rotate pairing
  credentials from the Mac app immediately.

## Supported versions

Only the latest release on `main` is supported. This is a personal tool with
no LTS commitment.
