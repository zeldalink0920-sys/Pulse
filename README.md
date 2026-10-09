# Pulse for iPhone

Native SwiftUI app for iOS 17 or newer. Bottom navigation: Home, Chats, Diary, Between Us. No menstrual-cycle module.

## Current status

Swift grammar and XcodeGen/GitHub Actions YAML checked locally. IPA packaging validation tests passed. **Xcode compilation, simulator UI tests, and real-device HealthKit verification have not run. No IPA has been built yet.** The current Windows host has no Xcode, and no connected GitHub repository is available for dispatching the macOS workflow.

## Build an unsigned IPA without owning a Mac

1. Put this folder in a private GitHub repository. Include `.github/workflows/build-ios.yml`.
2. Open Actions and run `Build iOS`. Pushing to `main` or `master` also triggers it.
3. The macOS runner generates an opaque app icon and Xcode project, then compiles an ARM64 iPhone archive.
4. Download `Pulse-unsigned-IPA-REQUIRES-SIGNING`. It contains `Pulse-unsigned.ipa`, packaged from the compiled `.app`, with its Mach-O platform verified. An unsigned IPA still needs valid signing before iPhone installation.
5. The separate simulator job tests startup, four-tab navigation, journal editing/persistence and Between Us letter persistence. `Pulse-UI-test-results` contains screenshots as XCTest attachments in the `.xcresult` bundle. These tests do not verify real HealthKit access.

No Apple Developer certificate is needed to compile the unsigned IPA. The workflow never substitutes zipped source files for a compiled application.

## Optional signed Ad Hoc export

Set repository secrets `IOS_CERTIFICATE_BASE64`, `IOS_CERTIFICATE_PASSWORD`, and `IOS_PROFILE_BASE64` to an Apple Distribution .p12 and an Ad Hoc profile. Set repository variable `APPLE_TEAM_ID`. The profile must match `com.pulse.personal`, enable HealthKit, and include the target iPhone UDID. Then download `Pulse-IPA` from the workflow. This route needs a paid developer membership; credentials must not be committed.

## Features and limits

- Screenshot-inspired white/gray embossed layout, Pulse orbital title, green startup orb, real time-aware greeting, configurable monthly/birthday/anniversary countdowns.
- Home carousel: Steps, Heart Rate, Sleep, Body. Each card opens a rounded detail sheet. Body's four metric cards switch its large value and weekly graph.
- HealthKit reads steps, heart rate, resting heart rate, HRV, oxygen saturation, sleeping wrist temperature, body mass, sleep and distance. Apple Watch data must be synchronized to the iPhone Health app. This app does not stream live watch measurements.
- Once HealthKit has been connected, Pulse refreshes on launch/foreground. Missing or unreadable records appear as `—`; Apple does not disclose read authorization in a way that distinguishes refusal from no records.
- Sleep uses one source for its stage timeline, prioritizing sources with sleep staging. Duration merges overlapping intervals. Sleep heart data is limited to intervals marked asleep. The display covers the past 24 hours and can include naps.
- Body shows latest available records, which can be old. Record timestamps appear in details. Weekly averages use readable daily averages.
- Diary supports dates, moods, editing, sharing and confirmed deletion. Messages and diary entries persist locally.
- Chats has Claude, Codex, and a work conversation list. **It is a local message log, not a connected AI service or live group chat.**
- Between Us has Plan/Receipt/Letter, date selection, a vector typewriter, autosaved text and system sharing. **Two-person remote synchronization is not implemented.**
- Artwork is drawn procedurally in SwiftUI; it is an interpretation rather than a pixel-identical rendering of the screenshots.

## Local static checks on Windows

Use Python 3.12 or newer:

```
python -m pip install --target .tools -r scripts/requirements-check.txt
python scripts/check-project.py
python scripts/test-package-ipa.py
```

These checks cannot establish whether Apple SDK types compile. The macOS CI build is required.