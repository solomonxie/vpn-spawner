# Privacy Policy — VPN Spawner

_Last updated: 2026-10-02_

VPN Spawner does not collect, transmit, or store your personal data on any server we control. We operate no server and no VPN service. Every VPN server the app creates runs in **your own** cloud account, paid for and controlled by you.

## Our commitment
We do not sell, use, or disclose to third parties any user data, for any purpose. We never see your traffic, your browsing, your IP address, or your cloud credentials.

## What the app stores on your device
- **Cloud credentials** you enter (AWS access key, Tencent Cloud SecretId/SecretKey): the secret parts in the iOS Keychain, the key IDs and settings in the app's local preferences.
- **Session details**: region, server ID and IP address, connection passwords generated for that server, start/end times, cost estimate, and an activity log. Local only.
- **VPN configuration**: the IKEv2 configuration is saved in iOS's VPN settings; its password is kept in the Keychain and removed when the server is destroyed.

## What leaves your device
- **Your cloud provider** (Amazon Web Services or Tencent Cloud) — requests to create, check, and delete the server and its firewall, signed with your credentials, sent directly from the device (or via a function you deployed in your own account). Their privacy policy governs that data.
- **Your VPN server** — while connected, your internet traffic passes through the server in your account, not through us. The server and its logs are deleted when the session ends; a cloud-side timer deletes it even if the app is closed or removed.
- **Public IP check services** — to set the server's firewall to your current IP and to run the optional privacy check, the app asks public "what is my IP" and test services (for example ipinfo.io, ip-api.com, ipify.org, icanhazip.com, ifconfig.me, checkip.amazonaws.com, ipip.net, cip.cc, ip.3322.net, speed.cloudflare.com, mirrors.tencent.com). They see your IP address as with any web request; nothing else is sent.

## Analytics and advertising
None. No analytics SDK, no crash reporting, no advertising identifiers, no tracking across apps or websites.

## Location
The privacy check reads only whether Location Services is switched on (yes/no). The app never requests or reads your location.

## Children
The app is not directed at children and collects no data from anyone.

## Deleting your data
Destroy ends a session and deletes its server and firewall from your cloud account. Deleting the app removes its local data. iOS may keep Keychain items after an app is deleted, so clear the credential fields in Settings first and revoke the key in your cloud console; the VPN entry can be removed in iOS Settings → VPN. Cloud resources and billing history in your own account remain yours to manage.

## Changes
Material changes to this policy will be published here with a new date.

## Contact
Questions or requests: https://github.com/solomonxie/vpn-spawner/issues
