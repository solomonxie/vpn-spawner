# Ephemeral Cloud VPN (VPN Spawner)

Native iOS app for launching temporary Tencent Cloud nodes in `ap-guangzhou`, configuring a Shadowsocks server, and cleaning up resources upon session expiry.

## Features

- **Lifecycle Orchestration**: One-tap provisioning of ephemeral Tencent Cloud CVM instances with automated Shadowsocks bootstrap.
- **Safety Deadlines**: Default 60-minute session countdown with automatic termination and teardown confirmation.
- **Client Integration**: One-tap Shadowrocket URI copy, deep-linking, and QR code display.
- **Dual Execution**: Supports direct Tencent Cloud CVM API calls or user-owned SCF container controller invocation.
- **Security**: Cloud credentials stored exclusively in iOS Keychain.
- **Demo / Sandbox Mode**: Full offline simulation mode to test UI and lifecycle without cloud costs.

## Architecture

- **iOS Client**: Native SwiftUI app (`VPNSpawner/`), built with XcodeGen.
- **SCF Controller**: Optional containerized controller (`controller/`) for cloud-side persistence and cleanup schedules.

## Building and Installing

```bash
# Generate Xcode project
xcodegen generate

# Build and install to connected device
xcodebuild -project VPNSpawner.xcodeproj -scheme VPNSpawner -configuration Debug -destination 'platform=iOS' build
xcrun devicectl device install app --device <UDID> <path-to-.app>
```
