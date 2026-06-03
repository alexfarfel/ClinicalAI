# ClinicalAI

## Current Status (update this each session)
- Prompt 1 COMPLETE: 14 Swift stubs created, duplicates resolved
- Xcode 16 auto-discovers Swift files — no pbxproj edits needed
- Next step: Prompt 2 — implement data models

## What this is
An iOS app that pairs with Meta AI smart glasses to function as an ambient clinical 
documentation assistant. The glasses capture audio and visual data during patient 
encounters. The app processes this through the Anthropic Claude API to generate 
structured SOAP-format physician notes incorporating physical exam findings. Phase 2 
adds a real-time AI diagnostic partner.

## Tech stack
- Swift 5.9 + SwiftUI (iOS 17 minimum)
- Meta AI glasses via Meta Wearables Swift SDK (verify current package URL at 
  https://developers.meta.com/)
- Anthropic Claude API (model: claude-sonnet-4-20250514)
- Swift Package Manager for dependencies

## Project structure
- ClinicalAI/App/ — app entry point and root navigation
- ClinicalAI/Features/Encounter/ — recording session management and active encounter UI
- ClinicalAI/Features/Notes/ — note generation, display, and editing (Phase 1)
- ClinicalAI/Features/Diagnostic/ — AI diagnostic partner chat interface (Phase 2)
- ClinicalAI/Services/GlassesService.swift — Meta SDK + Bluetooth connection
- ClinicalAI/Services/LLMService.swift — Claude API calls and prompt engineering
- ClinicalAI/Services/EncryptionService.swift — data encryption at rest
- ClinicalAI/Models/ — shared data structures

## Key rules — never break these
- API keys live in the iOS Keychain only. Never hardcode them in source files.
- Never persist raw audio or images after note generation is complete (patient privacy).
- All patient data must be encrypted at rest using CryptoKit.
- Always use async/await — no Combine, no callbacks.
- Every service must have a protocol and a Mock implementation for testing.
- Code must be extensively commented. The primary maintainer is a physician, not 
  a software engineer.

## Architecture pattern
MVVM: every Feature screen has a View (SwiftUI) and a ViewModel (@Observable).
Services are injected via protocol so they can be swapped for mocks during development.

## Physician workflow (what we're building toward)
1. Physician puts on glasses, opens the app, taps "Start Encounter"
2. App connects to glasses, audio recording begins
3. During exam, physician taps "Capture Finding" — glasses take a photo, physician 
   adds a brief annotation
4. Physician taps "End Encounter" — app sends transcript + images to Claude API
5. Claude returns a SOAP note incorporating visual exam findings
6. Physician reviews, edits, exports to EHR
7. (Phase 2) During the encounter, "Consult AI" opens a chat interface with real-time 
   differential diagnoses and testing suggestions

## Meta Wearables SDK
- Package: https://github.com/facebook/meta-wearables-dat-ios
- Imports: import MWDATCore, import MWDATCamera
- API reference: https://wearables.developer.meta.com/llms.txt?full=true
- The SDK works through the Meta AI app — glasses must be paired there first
- Key classes: Wearables (singleton), DeviceSession, Stream, AutoDeviceSelector
- Camera capture: stream.capturePhoto(format: .jpeg) triggers photoDataPublisher
- Audio: accessed via standard iOS Bluetooth audio profile (AVAudioSession)
- App Store submission not yet supported — distribute via release channels

## Known Mistakes — Never Do These
- WearableDevice does not exist in the MWDAT SDK. Never invent 
  type names — always verify against the API reference at 
  https://wearables.developer.meta.com/llms.txt?full=true
- Never wrap Text() views with Binding — pass String values 
  directly e.g. Text(device.name) not Text($device.name)
- Never use List(array) directly with custom types — always use 
  List { ForEach(array) { item in ... } }
- SwiftUI Views that initialize @Observable ViewModels must be 
  marked @MainActor at the struct level
- URLSession instances must never be named `session` — use 
  `urlSession` to avoid conflicts with EncounterSession 
  parameters
- Info.plist must never be added to Copy Bundle Resources — 
  Xcode processes it automatically
- Multi-line Swift string literals: every line inside must be 
  indented at least as far as the closing triple-quote
  
  ## Git Structure
- Outer repo: ~/Desktop/ClinicalAI (git lives here)
- Swift files live in ClinicalAI/ClinicalAI/
- Previously had broken submodule — fixed in commit 54d80b1
- Always commit from ~/Desktop/ClinicalAI

## Current Build Status
- Prompts 1-5 COMPLETE, build clean
- Next: Prompt 6 — Note review and export UI
- Next: Prompt 7 — AI diagnostic partner
- Then: live test with physical glasses

## MWDAT SDK Facts
- Correct imports: import
