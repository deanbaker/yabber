# Publishing Yabber on the App Store

Yabber was built as a personal app installed straight from Xcode. This is what it would take to
publish it. It was written on 8 November 2026 against the
[App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/) as they stood then,
so re-check them before submitting.

Already in place: a paid Apple Developer Program membership (team `Q2CXDBHY76`, individual), the
bundle IDs under `com.yabber-app.yabber`, and the App Group `group.com.yabber-app.yabber`.

## 1. Code changes (likely to fail App Review without them)

### Keyboard rules: guideline 4.4.1

The guideline says keyboard extensions must:

> - Provide keyboard input functionality (such as typed characters);
> - Provide a method for progressing to the next keyboard;
> - Remain functional without full network access and without requiring full access;

and must not:

> - Launch other apps besides Settings;

What that means for Yabber:

- [ ] **Full typing keyboard.** The keyboard only has mic, space, delete and return. It needs a full
      QWERTY layout with number and symbol pages, shift and caps lock, and the globe key. Competing
      apps such as SpeakUp ship one for this reason. This is the largest piece of work.
- [ ] **Works without Full Access.** Typing must work with Full Access off. Dictation can still
      require it (the keyboard needs Full Access to reach the App Group), as it does in competing
      apps. With Full Access off, show a short explanation on the mic key instead of a blocked
      keyboard.
- [ ] **Opening the app.** Opening Yabber from the keyboard breaks "must not launch other apps
      besides Settings" as written. Wispr Flow, SpeakUp and Spokenly all do it and are on the store,
      so Apple evidently allows a keyboard to open its own app for dictation. It remains the most
      likely reason for a rejection. Explain it in the reviewer notes (see section 3).
- [ ] **Buttons do what they say.** The rules also forbid repurposing keys, such as holding return to
      launch something. The current keyboard is fine; keep it that way.

### Background mic: guideline 2.5.4

> Multitasking apps may only use background services for their intended purposes: VoIP, audio
> playback, location, task completion, local notifications, etc.

- [ ] Keeping the mic on between dictations (the idle window) is a grey area, though competing
      apps ship with it. In the reviewer notes, explain that it's what lets the keyboard dictate
      without leaving the app, that the orange mic dot is visible throughout, that the user chooses
      the auto-stop time (1–30 min), and that they can end the session in the app.

### Privacy

- [ ] **Stop logging transcriptions.** `SharedLog` writes the first 80 characters of each
      transcription to `debug.log` in the App Group (`App/Yabber/DictationService.swift`, in
      `finish`). Log only lengths and timings in Release builds, or turn the shared log off
      outside Debug builds.
- [ ] **Privacy manifests.** Add `PrivacyInfo.xcprivacy` to both the app and the keyboard
      extension. List the required-reason APIs actually used, such as UserDefaults (reason
      `CA92.1`), and declare that no data is collected or used for tracking. Check whether
      FluidAudio ships its own manifest.
- [ ] **Privacy policy link in the app.** Guideline 5.1.1(i) requires a privacy policy linked both
      in App Store Connect and "within the app in an easily accessible manner". Add a link in the
      app's settings.

### Licences

- [ ] **Acknowledgements screen** in the app, also referenced in the description:
  - Parakeet TDT 0.6B v3 (NVIDIA), licensed **CC-BY-4.0**, which requires attribution. This applies
    to both [nvidia/parakeet-tdt-0.6b-v3](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3) and
    the Core ML conversion
    [FluidInference/parakeet-tdt-0.6b-v3-coreml](https://huggingface.co/FluidInference/parakeet-tdt-0.6b-v3-coreml).
  - [FluidAudio](https://github.com/FluidInference/FluidAudio), licensed **Apache-2.0**. Include its
    licence text and any NOTICE file.

### Release build

- [ ] Add `ITSAppUsesNonExemptEncryption = NO` to the app's Info.plist. The app only uses standard
      HTTPS (for the model download), which is exempt, so App Store Connect stops asking about
      export compliance on every upload.
- [ ] Add an archive-and-upload command to `scripts/app.sh`
      (`xcodebuild archive`, then `xcodebuild -exportArchive` with an App Store Connect export
      options plist), or use Xcode's Organizer. Automatic signing creates the Apple Distribution
      certificate and profiles.
- [ ] Set the version and build numbers (`MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` in
      `App/project.yml`). Each upload needs a new build number.
- [ ] Decide on the debug-only behaviour, such as the shared log, and check it's compiled out of
      Release builds.

### Model download

- [ ] The app downloads the 0.5 GB model from Hugging Face on first launch. Guideline 2.5.2 forbids
      downloading code that "introduces or changes features or functionality", but says nothing about
      model files, and similar apps download theirs. This should be acceptable. Make sure the first
      launch explains the download size and handles no connection gracefully. Bundling the model
      instead would avoid the dependency on Hugging Face, at the cost of a roughly 0.5 GB app.

## 2. Things only the account holder can do

- [ ] **Website (yabber-app.com):** confirm the domain is registered, then publish:
  - **A privacy policy** covering what's collected (nothing), that audio and text never leave the
    phone, that the model is downloaded from Hugging Face, that nothing is retained off the device,
    and how to delete data (delete the app).
  - **A support page** with a contact method.
- [ ] **Seller name:** an individual account shows "Dean Baker" as the seller. To show "Yabber",
      enrol as an organisation, which needs a D-U-N-S number for an ABN-registered business.
- [ ] **EU trader status (Digital Services Act):** to distribute in the EU, declare trader or
      non-trader status in App Store Connect. A trader's address, phone number and email are shown
      publicly on the listing. The alternative is to leave the EU out of the distribution countries.
- [ ] **Agreements:** a free app only needs the Free Apps agreement, which is accepted by default.
      A paid app or in-app purchases also need the Paid Apps agreement, banking and tax details.
- [ ] **Trademark (optional):** "Yabber" had no App Store matches in Australia when checked, and
      creating the app record reserves the name worldwide. A trademark search or registration with
      IP Australia is a separate decision.

## 3. App Store Connect

1. [ ] **Create the app record** with bundle ID `com.yabber-app.yabber`, named "Yabber". Do this
       early to reserve the name.
2. [ ] **Listing details:**
   - subtitle, description, keywords and promotional text;
   - category: Productivity;
   - age rating questionnaire;
   - support URL, privacy policy URL and copyright;
   - App Privacy label: **Data Not Collected**, once that's confirmed against the final code;
   - screenshots at 6.9-inch iPhone size (1320 × 2868 px; smaller sizes can be scaled from these);
   - optionally, an app preview video showing a dictation.
3. [ ] **Notes for the reviewer:**
   - how to add the keyboard and turn on Allow Full Access;
   - that the first launch downloads the model, and how long it takes;
   - why the keyboard opens Yabber (the keyboard can't use the microphone, so the app must start
     the session);
   - why the mic stays on between dictations, with the orange dot, the auto-stop setting and the
     End button as safeguards;
   - that no audio or text leaves the device;
   - a link to a short screen recording of the whole flow, which helps more than written steps.
4. [ ] **TestFlight:** upload a build, test it internally, and run through the full flow on a phone
       that has never had Yabber installed.
5. [ ] **Submit for review.** Reviews usually take a day or two. If it's rejected under 4.4.1 or
       2.5.4, reply in App Store Connect pointing to the reviewer notes and to comparable approved
       apps before changing the design.

## Open questions

- **Price:** free or paid? The apps in this space are free with optional paid features.
- **Platforms:** iPhone only (current), or iPad too?
- **Languages:** Parakeet v3 is multilingual, but the keyboard's `PrimaryLanguage` is `en-US`.
- **Minimum iOS version:** currently 18.0. The keyboard's way of opening the app needs Allow Full
  Access on iOS 26.
- **iOS 27:** there are reports that background Neural Engine inference broke in the first iOS 27
  beta. Test the CPU fallback on iOS 27 before release.
