<div align="center">

<br/>

# 🫀 BEFAST

### Stroke Detection Assistant

**An iOS app that runs the B.E.F.A.S.T. stroke recognition protocol in under 3 minutes — right on your phone.**

<br/>

![iOS](https://img.shields.io/badge/iOS-17%2B-black?style=flat-square&logo=apple)
![Swift](https://img.shields.io/badge/Swift-5.9-orange?style=flat-square&logo=swift)
![SwiftUI](https://img.shields.io/badge/SwiftUI-✓-blue?style=flat-square)
![License](https://img.shields.io/badge/License-MIT-green?style=flat-square)
![Status](https://img.shields.io/badge/Status-Active-brightgreen?style=flat-square)

</div>

-----

## What is this?

BEFAST is a guided stroke screening app for iPhone. When you suspect someone — or yourself — may be having a stroke, it walks you through 8 automated tests in about 3 minutes and tells you whether any warning signs are present.

It does not replace a doctor. It does not diagnose anything. What it does is give you a fast, structured way to assess the situation before emergency services arrive, so you’re not standing there guessing.

-----

## Why does it exist?

Stroke is the second leading cause of death worldwide. The damage it causes is directly proportional to how long it goes untreated — brain cells die at a rate of roughly **1.9 million per minute** during a stroke.

The problem is that most people freeze. The signs of a stroke can be subtle, easy to dismiss, or confusing in a high-stress moment. The B.E.F.A.S.T. protocol (Balance, Eyes, Face, Arms, Speech, Time) was developed by medical professionals to make recognition faster and more reliable — but most people don’t have it memorised.

BEFAST puts that protocol in your pocket, automates it, and removes the guesswork. You don’t have to remember what to look for. The app does that for you.

-----

## Who is it for?

**Anyone.** But especially:

- **Caregivers and family members** of people at higher stroke risk — older adults, people with hypertension, diabetes, or prior TIAs
- **People who live alone** who want a way to self-assess if something feels off
- **First responders and community volunteers** who want a structured tool before medical teams arrive
- **People in regions where emergency services take time** — having actionable data before the ambulance arrives can matter
- **Health-conscious individuals** who want periodic self-monitoring

You do not need any medical knowledge to use this app. It is designed to be operated by anyone, under stress, with no prior training.

-----

## What it tests

The app runs 8 automated tests mapped to the B.E.F.A.S.T. framework:

|Test                |What it measures                   |Technology used                |
|--------------------|-----------------------------------|-------------------------------|
|**Tap — Left Hand** |Dexterity and motor speed          |Touch input timing             |
|**Tap — Right Hand**|Bilateral dexterity asymmetry      |Touch input timing             |
|**Arm — Left**      |Arm stability and drift            |CoreMotion accelerometer       |
|**Arm — Right**     |Bilateral arm stability            |CoreMotion accelerometer       |
|**Balance**         |Body sway and postural control     |CoreMotion accelerometer       |
|**Speech 1 & 2**    |Clarity, accuracy, articulation    |SFSpeechRecognizer (on-device) |
|**Eyes**            |Gaze tracking, hemianopia screening|Vision framework + front camera|

Each test runs automatically — no buttons to press mid-test. Results are compared against clinical thresholds derived from the B.E.F.A.S.T. methodology.

-----

## What happens after

- A results screen shows which tests passed or flagged a warning
- If any warning is detected, the app surfaces a one-tap emergency call button
- Emergency contacts (configured in Settings) can be alerted via SMS automatically
- Results are saved locally to track changes over time
- The full result summary can be shared as plain text with a doctor or carer

-----

## ⚠️ Important disclaimer

> **This app is not a medical device and cannot diagnose a stroke or any medical condition.**
> If you suspect a stroke, call your local emergency number (112 / 911) immediately.
> Do not delay emergency care because of this app’s results — in either direction.
> This tool is for awareness and screening purposes only, based on the publicly documented B.E.F.A.S.T. method.

-----

<br/>

## Technical overview

<details>
<summary><strong>Architecture</strong></summary>

<br/>

The app uses a flat state machine rather than NavigationStack. A single `AppState` enum drives the entire view hierarchy from `ContentView`, which makes transitions fully controllable and avoids the NavigationStack edge cases that appear in time-sensitive medical UIs.

```swift
enum AppState {
    case splash, onboarding, disclaimer, home
    case intro(TestPhase), testing(TestPhase)
    case results(...), settings, history
}
```

All navigation is handled via a single `navigate(to:forward:)` function. Animation direction (push vs pop) is tracked with a `goingForward` bool. This keeps every transition consistent and testable.

</details>

<details>
<summary><strong>Sensor layer</strong></summary>

<br/>

**Accelerometer (Arm + Balance tests)**
`CMMotionManager` samples at 10Hz. For arm tests, it measures the RMS of acceleration excluding gravity on the vertical axis. For balance, it measures total sway magnitude against a vertical-hold baseline. Raw readings are averaged across the test window.

**Speech recognition**
Uses `SFSpeechRecognizer` with on-device processing (no network required). An `AVAudioEngine` tap feeds a `SFSpeechAudioBufferRecognitionRequest` in real time. Accuracy is scored by word intersection: the ratio of correctly spoken words to total target words, case-insensitive.

**Eye tracking**
`AVCaptureSession` feeds frames from the front camera to a `VNDetectFaceLandmarksRequest`. Left and right eye pupil positions are averaged per frame, smoothed over a 5-frame rolling window, and compared against a centre-gaze baseline. Deviation thresholds flag left/right visual field misses. All processing is on-device via the Vision framework.

</details>

<details>
<summary><strong>Data & persistence</strong></summary>

<br/>

`AppDataStore` is an `ObservableObject` backed entirely by `UserDefaults`. Test results are encoded as `[TestResult]` JSON and decoded on init. No external database, no network calls, no analytics — everything stays on device.

Results are prepended (newest first) and capped by the user clearing history manually. The history view shows per-test breakdowns and an overall pass/warn status.

</details>

<details>
<summary><strong>Notifications</strong></summary>

<br/>

`UNUserNotificationCenter` schedules a `UNCalendarNotificationTrigger` at 09:00 daily or weekly (Monday). Toggling the reminder off calls `removeAllPendingNotificationRequests`. Frequency changes reschedule immediately.

</details>

<details>
<summary><strong>Visual layer (iOS 26)</strong></summary>

<br/>

On iOS 26+, card components use `GlassEffectContainer` + `.glassEffect()` for native liquid glass rendering. On iOS 17–25, the same component falls back to a white background with layered shadows and `.ultraThinMaterial`. All animations use `spring(duration:bounce:)` presets. Numeric counters use `.contentTransition(.numericText())` for smooth digit transitions.

</details>

<details>
<summary><strong>Required Info.plist keys</strong></summary>

<br/>

```xml
<key>NSCameraUsageDescription</key>
<string>Used to track eye movement during the vision test.</string>

<key>NSMicrophoneUsageDescription</key>
<string>Used to record speech during the speech clarity test.</string>

<key>NSSpeechRecognitionUsageDescription</key>
<string>Used to transcribe and score spoken sentences during the speech test.</string>
```

All three permissions are requested contextually, not on launch. Permission denials are handled gracefully — speech and eye tests fall back to manual scoring.

</details>

<details>
<summary><strong>Project structure</strong></summary>

<br/>

```
ContentView.swift          — Everything (single-file architecture)
  ├── Design tokens         — Color + Animation extensions
  ├── Glass components      — LiquidCard, GlowCircle, PulsingRings
  ├── Data models           — EyesResult, TestResult, AppState, TestPhase
  ├── Services              — AppDataStore, ReminderManager, OrientationManager
  ├── Screens               — Splash, Onboarding, Home, Disclaimer, Settings, History
  ├── Test flow             — Intro → Testing → Results per phase
  └── Test views            — Dexterity, Arm, Balance, Speech, Eyes
```

The app is intentionally single-file for portability and simplicity. It can be split into feature modules if the project grows.

</details>

-----

## Requirements

- iOS 17.0 or later
- iPhone with front-facing camera (for eye test)
- Microphone access (for speech test)
- Motion sensors / accelerometer (standard on all iPhones)

-----

## Getting started

1. Clone the repo
1. Open in Xcode 16+
1. Add the three `Info.plist` privacy keys listed above
1. Build and run on a physical device (motion and camera do not work in Simulator)

-----

## Contributing

Issues and PRs are welcome. If you’re a medical professional and see something in the scoring thresholds that should be adjusted, please open an issue — that kind of input is exactly what this project needs.

-----

## License

MIT — see `LICENSE` for details.

-----

<div align="center">
<br/>
<sub>Built with SwiftUI · CoreMotion · Speech · Vision · AVFoundation</sub>
<br/>
<sub>Based on the B.E.F.A.S.T. stroke recognition method</sub>
<br/><br/>
</div>
