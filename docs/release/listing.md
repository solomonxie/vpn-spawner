# Publishing VPN Spawner — TestFlight first

Every field below is ready to paste. `TODO` = only you can supply it.
App Store Connect paths start at **Apps → VPN Spawner →**.

| | |
|---|---|
| Bundle ID | `com.example.vpnspawner` |
| SKU | `vpnspawner-ios` |
| Version | `1.0` (`MARKETING_VERSION` in `project.yml`) |
| Build | timestamp, set by `make release` |
| Devices | iPhone only (`TARGETED_DEVICE_FAMILY = 1`) |
| Min iOS | 17.0 |
| Privacy Policy URL | `https://github.com/solomonxie/vpn-spawner/blob/master/docs/release/privacy-policy.md` |
| Support URL | `https://github.com/solomonxie/vpn-spawner/issues` |
| Setup guide (users) | `https://github.com/solomonxie/vpn-spawner/blob/master/docs/setup.md` |

Target: **App Store Connect + TestFlight**. The App Store itself needs an Organization account (Guideline 5.4, see B1); the store listing further down is kept for when one exists.

---

## Blockers / account requirements

### B1. Guideline 5.4 — Organization account (blocks the App Store, may affect external TestFlight)

5.4: VPN apps "may only be offered by developers enrolled as an organization", must use `NEVPNManager`, must declare data use on an app screen before use, and must not sell/use/disclose data.

- Account is **Individual** → no App Store release. TestFlight is the path (below).
- `NEVPNManager`: satisfied (IKEv2, Personal VPN entitlement `allow-vpn`).
- Data declaration: done — first-launch **Your data** screen (must tap *Agree and Continue*), also at Settings → Data use (`VPNSpawner/Views/DataUseView.swift`).
- Later, for the App Store: enroll an organization (legal entity + D-U-N-S + website), new membership or ask Apple Developer Support to convert this one.

### B2. Public URLs

Privacy Policy, Support and setup-guide URLs point into `solomonxie/vpn-spawner`. They work once the repo is public; until then they 404. External TestFlight requires the privacy policy URL; the in-app setup links need `docs/setup.md` on `master`.

### B3. Reviewer access

- **Demo mode**: Settings → Demo mode simulates launch → ready, no cloud calls; Connect is disabled.
- Real connection: a review-only AWS key.
  - [ ] TODO: IAM user `vpn-spawner-review` with the invoke-only policy (`lambda:InvokeFunction` on `vpn-spawner-controller`, see `docs/setup.md` → AWS step 4) → access key. Only in Beta App Review / App Review fields, never in the repo.
  - [ ] Controller Lambda deployed and working; AWS Budgets alert (e.g. $5).
  - [ ] Deactivate the key after review; a fresh one per review.

### B4. Regions — exclude China mainland

- **China mainland: exclude** (VPN apps need an MIIT license there).
- Also restrict or license VPNs — exclude unless you've checked local rules: Russia, Belarus, United Arab Emirates, Oman, Turkmenistan, Pakistan. (Iran, North Korea, Syria, Cuba have no storefront.)
- Set in **Pricing and Availability** before inviting external testers; if App Store Connect offers a separate TestFlight country list, set the same exclusions there.

### B5. Export compliance — answered

`ITSAppUsesNonExemptEncryption = false` (OS-provided crypto only), see [Export compliance](#export-compliance).

### B6. Smaller review risks

- Protocol wording is neutral/technical (no "hard to detect" style claims).
- Non-IKEv2 protocols are not tunneled by this app; it hands links/QR codes to other apps. Stated in the notes.
- `NSAllowsArbitraryLoads = true`: nodes are reached by bare IP over HTTP. Justified in the notes.
- App icon: opaque, no alpha.

---

## TestFlight

### Internal vs external

| | Internal testing | External testing |
|---|---|---|
| Who | Up to **100** members of your App Store Connect team (Users and Access) | Up to **10,000** people, by **email invite** or **public link** |
| Review | **None** — available once the build finishes processing | **Beta App Review** for the first build of each version; later builds of that version usually go straight out |
| Setup | Add the person as a user (role e.g. Developer or Marketing, limited to this app), then to an internal group | Group + **Test Information** (below) + privacy policy URL |
| 5.4 risk | None in practice | **Risk:** Beta App Review follows the App Review Guidelines and may still reject a VPN app from an Individual account. Fallback: internal testing |

Builds expire after **90 days**; upload a new one (`make release`) to keep testing.

### Steps

1. [ ] Apple Developer account active; App Store Connect → **Business**: no pending agreement banner.
2. [ ] `cp Config/Local.xcconfig.example Config/Local.xcconfig`, set your Team ID and bundle ID (gitignored). `brew install xcodegen` if missing.
3. [ ] **Apps → + → New App**: iOS, Name `VPN Spawner`, English (U.S.), Bundle ID `com.example.vpnspawner`, SKU `vpnspawner-ios`, Full Access. (The Personal VPN capability is registered by the first automatic-signing build.)
4. [ ] `make release` → tests, Release build, archive, upload. Processing 15–60 min.
5. [ ] **TestFlight** → the build shows no "Missing Compliance".
6. [ ] Fill **TestFlight → Test Information** (below).
7. [ ] **Internal**: TestFlight → Internal Testing → **+** group `Team` → add testers (must be users in Users and Access first) → enable automatic distribution. Testers install the TestFlight app and accept the email.
8. [ ] **External** (optional, after B2–B4): Pricing and Availability set (B4) → TestFlight → External Testing → **+** group `Beta` → add the build → **Submit for Review** → after approval add testers by email or **Enable Public Link** (optionally cap testers).
9. [ ] Smoke test on the TestFlight build (step list in [Smoke test](#smoke-test)).

### Test Information (TestFlight → Test Information)

| Field | Value |
|---|---|
| Beta App Description | below |
| Feedback Email | TODO (an address you read; shown to testers) |
| Marketing URL | `https://github.com/solomonxie/vpn-spawner` |
| Privacy Policy URL | `https://github.com/solomonxie/vpn-spawner/blob/master/docs/release/privacy-policy.md` |
| Beta App Review → Contact First / Last Name | TODO |
| Beta App Review → Phone | TODO (with country code) |
| Beta App Review → Email | TODO |
| Beta App Review → Sign-In Required | **On** — User name: review AWS **Access key ID**; Password: its **Secret access key** (B3). TODO |
| Beta App Review → Review Notes | below |

Beta App Description (paste):

```
VPN Spawner creates a temporary VPN server in your own AWS or Tencent Cloud account, connects your iPhone to it over IKEv2, and deletes the server when your timer ends.

You need your own cloud account and a limited access key. Setup guide: https://github.com/solomonxie/vpn-spawner/blob/master/docs/setup.md

The app has no account and no backend: it talks only to your cloud provider and your own server. Your provider bills you directly, usually a few cents per hour. Settings → Demo mode shows the whole flow without a cloud account.
```

What to Test (build → Test Details, paste):

```
Thanks for testing VPN Spawner 1.0.

1. First launch: read the "Your data" screen and tap Agree and Continue.
2. Settings (gear): choose AWS or Tencent Cloud, tap Paste credentials, then Test connection. No cloud account? Turn on Demo mode instead.
3. Home: pick a region and auto-destroy time, tap Launch. A server is ready in about 2 minutes.
4. Tap the ring to connect (iOS asks once to add a VPN configuration). Then try Full privacy check.
5. Extend the time once, then Destroy. The VPN should disconnect and Settings → Activity log should show the cleanup verified.

Please report: anything that got stuck, wrong or confusing text, a server that was not deleted, and your iPhone model and iOS version. Use the TestFlight app's Send Beta Feedback (screenshot) or the feedback email.
```

Beta App Review notes (paste):

```
VPN Spawner creates a temporary VPN server in the user's OWN cloud account and connects to it with IKEv2 through NEVPNManager. We operate no VPN service and no server, and collect no data. A data-use declaration is shown on first launch and must be accepted (also in Settings → Data use).

HOW TO TEST
No account or login with us. The app needs the user's own cloud key. Please use the AWS key in Sign-In Information (user name = Access key ID, password = Secret access key):
1. First launch: "Your data" screen → Agree and Continue.
2. Settings (gear) → Cloud: AWS → enter both values → Test connection.
3. Back → AWS, region Oregon → Launch. Ready in about 2 minutes.
4. Tap the ring → iOS asks to add a VPN configuration → Allow. Status shows Connected.
5. Full privacy check: exit IP equals the server IP.
6. Destroy → the server and its firewall are deleted, the VPN disconnects.
That key can only invoke our test controller function; servers it creates delete themselves. Without a key, Settings → Demo mode simulates the flow (Connect disabled).

OTHER PROTOCOLS
"Other apps" shows links/QR codes for protocols served by the user's own server (Shadowsocks, VLESS, VMess, Trojan, Hysteria2, WireGuard) for use in separate client apps the user already has. This app itself tunnels only IKEv2, via NEVPNManager.

NETWORK
Cloud APIs (AWS Lambda; Tencent Cloud CVM/VPC/SCF) are called from the device with the user's key. The user's server is reached by bare IP over HTTP (/health, /client.json), hence NSAllowsArbitraryLoads; its firewall admits only the user's IP. Public IP-check services (ipinfo.io, ip-api.com, ipify.org, icanhazip.com, ifconfig.me, checkip.amazonaws.com, ipip.net, cip.cc, ip.3322.net) find the user's IP for the firewall and the privacy check. No analytics, ads, crash reporting or payments.

AVAILABILITY
Not offered in China mainland or other territories that require a VPN license.
```

### Smoke test

- Settings → AWS → Paste credentials → Test connection.
- Home → AWS region → Launch → ready in ~2 min.
- Connect (IKEv2) → iOS asks once → Connected, VPN icon.
- Full privacy check → exit IP = server IP.
- Other apps → QR code / Share for one non-IKEv2 protocol.
- +10 minutes, then Destroy → VPN disconnects; Activity log shows cleanup verified.
- Demo mode on → Launch → simulated session → Destroy → Demo mode off.
- Fresh install: "Your data" sheet appears and can't be dismissed without Agree; Settings → Data use shows it again.

---

# App Store (needs an Organization account, B1)

Everything below is ready for when the account is an organization. Submit: `1.0 Prepare for Submission` → Build → fill the pages → **Add for Review** → **Submit for Review**. Release manually, then deactivate the review key and `git tag v1.0`.

## App Store Connect pages

### `iOS App → 1.0 Prepare for Submission`

| Field | Value |
|---|---|
| Previews and Screenshots | [Screenshots](#screenshots) |
| Promotional Text | below |
| Description | below |
| Keywords | below |
| Support URL | `https://github.com/solomonxie/vpn-spawner/issues` |
| Marketing URL | leave blank |
| Version | `1.0` |
| Copyright | `2026 <organization legal name>` (B1) |
| Routing App Coverage File | leave blank |
| Build | the uploaded build |
| App Review → Sign-In Required | **On** — User name: the review AWS **Access key ID**; Password: its **Secret access key** (B3). TODO |
| App Review → Contact First / Last Name | TODO |
| App Review → Phone | TODO (with country code, e.g. `+1 …`) |
| App Review → Email | TODO |
| App Review → Notes | below |
| App Review → Attachment | the screen recording (optional, recommended) |
| Version Release | **Manually release this version** |

Promotional Text (no price wording):

```
Your own VPN server in your own AWS or Tencent Cloud account, ready in about two minutes and gone when time's up. Nothing passes through us.
```

Description:

```
VPN Spawner creates a private VPN server in your own cloud account, connects your iPhone to it, and deletes it when you're done. Nobody else's server, nobody else's logs: the server is yours, for as long as you need it.

No sign-up. We run no server and never see your traffic.

ONE-TAP SERVER
• Launch a fresh server on Amazon Web Services or Tencent Cloud in about two minutes
• Pick the region: Oregon, N. Virginia, Canada, Frankfurt, Tokyo, Singapore, Hong Kong, Taipei and more
• Firewall opens only to your iPhone's current IP; add another IP with one tap
• A new server and a new IP every time

CONNECT
• IKEv2 connects right in the app through the iOS VPN settings: no profile, no other app
• All traffic, IPv6 included, goes through the tunnel
• Also serves Shadowsocks, VLESS, VMess, Trojan, Hysteria2 and WireGuard for clients you already use: import by link, QR code or subscription link

GONE WHEN TIME'S UP
• Choose 10, 30, 60 or 120 minutes; extend any time
• The server deletes itself when the timer ends, even if the app is closed or deleted
• Destroy removes the server and its firewall immediately, and the app checks they are gone

PRIVACY CHECK
• Exit IP, provider and location as websites see them
• IPv6 and DNS leak checks, latency and speed
• What a VPN can't hide: Location Services and time zone

YOUR KEYS, YOUR BILL
• Your cloud key stays in the iPhone's Keychain and is sent only to your cloud provider
• Least-privilege permission templates for each provider, built in
• Your provider bills you directly, typically a few cents per hour plus data transfer
• Demo mode shows the whole flow with no cloud account and no cost

Requires your own Amazon Web Services or Tencent Cloud account.

No analytics and no tracking.
```

Keywords (99/100 — "vpn", "private", "cloud" omitted, the name and subtitle already index them):

```
ikev2,shadowsocks,aws,tencent,server,self-hosted,proxy,temporary,disposable,privacy,tunnel,wifi,ec2
```

App Review Notes (also the Guideline 2.1 answers Apple asked to keep here):

```
On first launch a data-use declaration is shown and must be accepted (also in Settings → Data use). No account or login with us. The app needs the user's own cloud key. For review, please use the AWS key in Sign-In Information (user name = Access key ID, password = Secret access key): Settings (gear) → Cloud: AWS → enter both → Test connection. That key can only invoke our test controller function; servers it creates self-destruct. Without a key, Settings → Demo mode simulates the whole flow (Connect is disabled in demo).

PURPOSE AND AUDIENCE
VPN Spawner is for people who want a private VPN they own rather than a shared commercial VPN service: travellers and remote workers on untrusted Wi-Fi, and technical users with a cloud account. It creates a temporary server in the user's own AWS or Tencent Cloud account, connects the iPhone to it, and deletes it when time is up. We operate no VPN servers and receive no user data.

HOW TO USE THE MAIN FEATURES
1. Home: choose AWS, a region (e.g. Oregon), duration, then Launch. Ready in about 2 minutes.
2. Connect: iOS asks once to add a VPN configuration (IKEv2 via NEVPNManager). Status shows Connected.
3. Full privacy check: exit IP, IPv6/DNS leaks, latency, speed.
4. Other apps: links/QR codes for Shadowsocks and other protocols, for use in separate client apps the user already has. This app tunnels only IKEv2, through NEVPNManager.
5. Extend (+10/30/60 min) or Destroy: the server and its firewall are deleted and the VPN disconnects.
6. Settings: cloud key, "Runs from" (this iPhone or the user's own cloud function), permission templates, activity log, Demo mode.

EXTERNAL SERVICES
- Amazon Web Services (Lambda, EC2) and Tencent Cloud (CVM, VPC, SCF) APIs, called directly from the device with the user's key, in the user's own account.
- The user's own server (bare IP; /health and /client.json over HTTP, hence NSAllowsArbitraryLoads; the firewall admits only the user's IP).
- Public IP-check services (ipinfo.io, ip-api.com, ipify.org, icanhazip.com, ifconfig.me, checkip.amazonaws.com, ipip.net, cip.cc, ip.3322.net) to set the firewall to the user's IP and for the privacy check; speed.cloudflare.com and mirrors.tencent.com for the speed test. No personal data is sent.
No analytics, advertising, crash reporting, authentication or payment services. We run no server.

REGIONAL DIFFERENCES
The app works the same everywhere. It is not offered in China mainland. Available server regions depend on the cloud provider chosen.

REGULATION
The developer provides no VPN service: every server runs in the user's own cloud account, billed by their provider. Data use: the app collects nothing; we do not sell, use or disclose any user data (see the privacy policy). The IKEv2 tunnel uses Apple's NetworkExtension (NEVPNManager). The app is not distributed in territories that require a VPN license.
```

What's New: not shown for a first version. From 1.1 on, write it here.

### `General → App Information`

| Field | Value |
|---|---|
| Name | `VPN Spawner` |
| Subtitle (29/30) | `Private VPN in your own cloud` |
| Category — Primary | Utilities |
| Category — Secondary | Developer Tools |
| Content Rights | **No**, it does not contain, show, or access third-party content |
| Age Rating | **Edit** → answer below → result **4+** |
| License Agreement | Apple standard EULA (default) |
| Privacy Policy URL | `https://github.com/solomonxie/vpn-spawner/blob/master/docs/release/privacy-policy.md` |

Age rating questionnaire — every answer:

| Section | Answer |
|---|---|
| Parental controls / age assurance | No |
| Unrestricted web access | No (no in-app browser; test links open Safari) |
| User-generated content | No |
| Messaging and chat | No |
| Advertising | No |
| Violence, sexual content, profanity, horror, mature themes | None |
| Alcohol, tobacco, drugs | None |
| Medical or treatment information / health & wellness | None |
| Gambling, simulated gambling, contests, loot boxes | None / No |
| Made for Kids | No |

Regional (Korea, China Mainland, Vietnam) — leave unset.
**Digital Services Act** trader status: **Not a trader** (free, no monetization) — if App Store Connect blocks EU availability without it, answer this in Business → Compliance. An organization account publishes its address if you declare trader.

### `App Store → Trust & Safety → App Privacy`

| Field | Value |
|---|---|
| Privacy Policy URL | same as above |
| Do you or your third-party partners collect data from this app? | **No, we do not collect data from this app** |

Then **Publish**. Label shows "Data Not Collected".

Grounded in the code:
- No analytics/ads/crash SDK, no dependencies at all (no SPM packages or Pods in `project.yml`).
- Cloud keys: Keychain (`KeychainStore`, `NativeVPNController`) + `UserDefaults`; sent only to `*.tencentcloudapi.com` / `lambda.<region>.amazonaws.com`, the user's own account.
- Traffic goes to the user's own server, never to us.
- IP-check services answer in real time and get nothing but the request; no partnership, so not "collected".
- `CoreLocation` is used only for `locationServicesEnabled()` (yes/no) — no permission prompt, no location read.

Re-check before each submission:

```
grep -rnE "analytics|firebase|sentry|amplitude|mixpanel|posthog|bugsnag|https?://" VPNSpawner project.yml
```

### `App Store → Trust & Safety → App Accessibility`

Skip for 1.0 rather than over-claim.

### `App Store → Monetization → Pricing and Availability`

| Field | Value |
|---|---|
| Base Country or Region | United States (USD) |
| Price | **Free** ($0.00) |
| Availability | All countries or regions **except China mainland** (required) — also untick Russia, Belarus, United Arab Emirates, Oman, Turkmenistan, Pakistan unless you've checked local VPN rules (B4) |
| Tax Category | App Store software (default) |
| iPhone and iPad Apps on Apple Silicon Macs | **Off** (VPN configuration and Keychain paths untested on Mac) |
| Apple Vision Pro | Off |

### Not needed for 1.0

In-App Purchases, Subscriptions, In-App Events, Custom Product Pages, Product Page Optimization, Promo Codes, Game Center, Featuring Nominations, Ratings and Reviews, History.

---

## Screenshots

App Store Connect slot **iPhone 6.9" Display** takes `1320 × 2868`; `6.5"` (`1284 × 2778`) is optional. Upload the 6.9" set; App Store Connect scales it for smaller phones.

**Not captured yet** — the repo has no real screenshots. Checklist:

1. `make device` (Release). Use the AWS key; pick a non-home region (e.g. Oregon). Real session, so Connect is enabled and there's no Demo badge.
2. Status bar: full battery, Wi-Fi, no notifications. Side button + Volume Up per shot.
3. **Keep your home IP out**: don't show the "Access → Allowed IPs" section; the server IP is fine (it's destroyed afterwards).
4. Shots, in upload order:
   1. **Launch** — idle screen: AWS, region, protocols, auto-destroy, Launch button
   2. **Provisioning** — progress steps mid-launch ("Step 3 of 4")
   3. **Connected** — Ready screen, IKEv2 Connected, countdown ring
   4. **Privacy check** — results with exit IP passing
   5. **Other apps** — protocol list, or the QR sheet for one protocol
   6. **Extend** — the +10/+30/+60 menu or the countdown "left before the server deletes itself"
   7. **Settings** — Runs from comparison + key section (key masked, ID cropped or a dummy)
   8. **Permissions** — "Permissions this key needs" guide
5. AirDrop to the Mac, e.g. `~/Desktop/shots/`, then:

```
make screenshots SHOTS=~/Desktop/shots
```

Outputs `docs/release/screenshots/6.9` and `6.5` (JPEG, no alpha). Drag the 6.9 files into the 6.9" slot.

App Preview video: skip for 1.0.

---

## Guideline 2.1 "Information Needed" (new developer accounts)

Apple wants a screen recording plus answers 2–6. The answers are the App Review Notes further down — paste them into the reply **and** into App Review → Notes.

Record the build Apple will review (also useful for Beta App Review questions). If it's a new build, upload it first (`make release`), pick it under **Build** on the `1.0` page, and install it from TestFlight.

Recording (the build Apple reviews, on the iPhone, current iOS):
1. iPhone Settings → Control Center → add **Screen Recording**. Turn on Do Not Disturb.
2. Before recording: enter the review AWS key in Settings (so no key appears on screen), destroy any running server, delete the app's entry in iOS Settings → VPN (so the "Add VPN Configurations" prompt shows). Swipe the app away.
3. Start recording, then launch the app from the Home Screen.
4. ~4 minutes:
   1. Idle screen: cloud AWS, region (e.g. Oregon), protocols, auto-destroy 10 min, cost hint.
   2. Settings: Runs from, AWS key masked, Permissions this key needs, Demo mode toggle; back.
   3. Launch → progress steps (firewall, launch, boot, install) → Ready. Trim the wait if long.
   4. Connect → iOS "Add VPN Configurations" → Allow → passcode → Connected, VPN icon.
   5. Full privacy check → exit IP equals the server IP.
   6. Other apps → Show QR code for Shadowsocks (explains import into another app).
   7. Destroy → confirm → VPN disconnects, back to "No server running".
   8. Settings → Activity log → the session with cleanup verified.
5. Stop. Photos → trim → share the video.

Reply: `App Review` in App Store Connect → the message → **Reply**, attach the video (or an unlisted YouTube/iCloud link if it's too large), paste:

```
Hello, thank you for the review. Answers below, and the same text is now in the App Review Information notes.

1. Screen recording attached, captured on an iPhone running the latest iOS, starting from launch. It shows a real server being created in our test AWS account, the VPN connecting through the iOS VPN settings, and the server being destroyed. The app has no account registration or login (so no account deletion flow), no user-generated content, and no paid content.

[paste the App Review Notes block from PURPOSE AND AUDIENCE to the end]
```

---

## Export compliance

No page for it in App Store Connect — `ITSAppUsesNonExemptEncryption = false` in `Info.plist` (set in `project.yml`) answers it at upload.

Why `false` is correct here, even for a VPN:

- IKEv2 tunnel: configured through `NEVPNManager`; iOS's built-in IKEv2 client does the encryption (AES-256, SHA-256, DH group 14). Encryption **within Apple's operating system**.
- HTTPS (`URLSession`) to cloud APIs and IP-check services: OS-provided.
- Request signing: `CryptoKit` SHA-256/HMAC-SHA256 (AWS SigV4, Tencent TC3) — authentication only, and Apple's framework.
- Secrets in the Keychain: OS-provided.
- No bundled crypto library (no OpenSSL, WireGuard-go, sing-box, etc. in the binary). Shadowsocks/VLESS/WireGuard run on the user's server, installed there by `controller/bootstrap.sh` from upstream; on the phone they're handed to other apps as links.

If asked (TestFlight → build → **Manage**): "What type of encryption algorithms does your app implement?" → **None of the algorithms mentioned above**. No France declaration (that question only follows "Standard encryption algorithms …"), no documentation upload, no BIS self-classification report.
Verify: TestFlight → the build is **not** marked "Missing Compliance".

Flip it to `true` (and answer "Standard encryption algorithms", Yes for France, then file the French declaration and the annual BIS mass-market self-classification report) only if the app ever bundles its own crypto, e.g. an in-app WireGuard / sing-box tunnel via a Packet Tunnel Provider.

---

## Localization

None for 1.0: the app's UI is English only (no `.lproj` / `.xcstrings`), and China mainland is excluded. Don't add a 简体中文 listing until the app itself is localized.
