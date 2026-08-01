# ShellHarbor iOS

Native SwiftUI iPhone/iPad application. Open
`ShellHarborIOS.xcodeproj` or build a simulator target with:

```bash
xcodebuild -project ios/ShellHarborIOS.xcodeproj \
  -scheme ShellHarborIOS \
  -sdk iphonesimulator \
  -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO build
```

The app includes persisted Remote and shared Proxy profiles, protected OpenSSH
private-key import, locally encrypted password/auth-key storage, interactive
host-key confirmation, grouped multi-select Remote management, independent
restorable and renameable Sessions, Citadel/SwiftNIO SSH PTY and SFTP,
pauseable file transfers, manual-only inspection, SwiftTerm, native Mosh,
jump-host modes, and an embedded Go tsnet Tailscale XCFramework. The iOS target
intentionally supports only iPhone/iPad; use the repository's native
`ShellHarbor` target on macOS.
