# Release: TestFlight and App Store

Bundle ID `com.example.vpnspawner` · iOS 17.0+ · iPhone only, portrait.

Target: App Store Connect + **TestFlight** (internal, then external). The App Store needs an Organization account for VPN apps (Guideline 5.4); read the Blockers in `listing.md` first.

- [`listing.md`](listing.md) — blockers, TestFlight steps and fields, then every App Store field, ready to paste
- [`privacy-policy.md`](privacy-policy.md) — the policy; its GitHub URL is the Privacy Policy URL (repo must be public)
- `screenshots/6.9`, `screenshots/6.5` — from `make screenshots SHOTS=<dir>`. **Gitignored:** shots show server and home IPs. None captured yet; checklist in `listing.md`.

Before the first build: `cp Config/Local.xcconfig.example Config/Local.xcconfig` and put your
Apple Developer Team ID in it. Gitignored — an account identifier does not belong in the repo.

Upload a build: `make release` — offline tests, generates the project, builds, archives, signs, uploads.
Nothing in Xcode. Build number is a timestamp unless you pass `BUILD=`. `make help` lists the rest.

Versioning: `MARKETING_VERSION` in `project.yml` is the user-visible version; bump it per
release. `CURRENT_PROJECT_VERSION` is set per upload by the script and never committed.
