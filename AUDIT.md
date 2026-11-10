# AUDIT — `instant_barcode_scanner`

## Status (2026-11-10, post-close-out)

- **Fixed on main:** A3 (dispose cancels a pending permission prompt; held-drive
  regression test), A4 (still images are downsampled; allocation-bound JVM
  test), A5 (activity display + main-thread metrics; off-device geometry tests),
  A6 (Dart 3.2 / Flutter 3.16 floor, guarded by a pubspec test), A9
  (`unsupported_platform` off Android, with platform-override tests), A10
  (Android manifest `uses-feature` opt-out, guarded by a README test).
- **Corrected, not code defects:** A1 (the 0.2.0 source and metadata URLs are
  intact; the original claim was an artifact of the dev checkout) and A2 (the
  real CI already compiled Kotlin; the three remaining gaps were closed in
  PR #22).
- **Remaining:** A5's display-source change has no off-device red test (it
  needs an `Activity`/`Display`). A7 is deferred: torch is live-only by design
  and `torchEnabled` covers the pre-live case; changing it needs a pending-torch
  state. A8 (enum/platform policy) and A15 (dispose/background docs) are
  docs-only; A11–A14 are historical or dev/example-only. The dev checkout still
  diverges from the mirror by design.
- **Waiting on the operator:** publish 0.3.0 (version bump, tag, publish).

- **Date:** 2026-11-10
- **Package:** `instant_barcode_scanner` (pub.dev, unverified uploader, BSD-3-Clause, Android-only plugin)
- **Audit target:** the **published 0.2.0 archive** (`https://pub.dev/api/archives/instant_barcode_scanner-0.2.0.tar.gz`, published 2026-11-01T15:17:22Z, sha256 `fba7d5a4dcd23b70638f5294c87e883b3197b3de827becacbfe734f55e98db58`), against the repository `/home/admin/projects/publish/instant_barcode_scanner` — the GitHub mirror of `schleunigst/instant_barcode_scanner` — at `main` = `036f7f3433d9787e77745f5b34c7d6687a171caa`, tag `v0.2.0`.
- **Method:** read all hand-written Dart and Kotlin sources end to end; ran `flutter analyze`, `dart pub outdated`, `dart pub publish --dry-run`, `flutter test`, `dart format --set-exit-if-changed` and `flutter build apk --debug` against the real checkout (analyze/test/dry-run were also run against the pristine archive); inspected the pub.dev API and page HTML; read the pub-dev server source.

**Citation convention.** Unprefixed paths refer to the 0.2.0 sources, which are byte-identical in the published archive and in `main` @ `036f7f3` for every package file. `repo@main:` marks the stale dev checkout (`/home/admin/projects/instant_barcode_scanner`, 0.1.0) only where a finding concerns it.

---

## 0. Provenance and scope

| | Published 0.2.0 | Repository `main` @ `036f7f3` |
|---|---|---|
| `version:` | `0.2.0` | `0.2.0` |
| commit | — | `036f7f3` "Prepare 0.2.0 release (#21)" |
| tag | — | `v0.2.0`, annotated `82e5a1d` -> `036f7f3` |
| package files | — | byte-identical to the archive (lib, test, android, example, README, CHANGELOG, pubspec, pigeons) |
| metadata URLs | 200 / 200 | 200 / 200 |
| `flutter test` | 100 tests | 100 tests |
| CI | — | `.github/workflows/ci.yml`: `test`, `example`, `publish-check`; this PR adds `android-instrumented` |

Two files account for the only archive/repo differences: the archive also contains `example/lib/verify_main.dart` (present and identical in the publish checkout, but **untracked**, so `pub publish` shipped it) and a generated `example/.../GeneratedPluginRegistrant.java` (gitignored). The release was cut from a dirty working tree; that is a provenance quirk, not a missing source.

### Root cause of the first audit

The brief named `/home/admin/projects/instant_barcode_scanner` as "the repo". That directory is the **dev checkout**: its `main` is 0.1.0, its history diverges from the public mirror, it had **no git remote configured**, and its 0.1.0 `pubspec.yaml` points at `github.com/instantbarcode/...` (HTTP 404). The environment's own `~/.config/opencode/AGENTS.md` states: "Dev checkout: /home/admin/projects/instant_barcode_scanner; GitHub mirror: /home/admin/projects/publish/instant_barcode_scanner" and "The dev checkout's git history diverges from the public mirror's history; make GitHub changes in the publish checkout". The first audit read only the dev checkout, so its A1 and A2 described that clone, not the project. The project's source, tag, and metadata URLs are intact.

---

# Part 1 — What the download number means

## 1.1 The authoritative definition

pub.dev's own documentation defines it precisely:

> "Pub.dev tracks and stores how many times each version of each package gets downloaded. This is used to display package usage metrics. The displayed download counts on pub.dev are aggregates based on raw server-side numbers counting the times a package archive has been downloaded from the server."
> — <https://pub.dev/help/scoring#download-counts> (`pub-dev/doc/help-scoring.md:29-33`)

> "The download count is not a direct measure of how many users a package has. A package can have a high usage with relatively low download counts, because the pub client caches the downloads in the `PUB_CACHE`."
> — same page, line 35

> "The download counts can also be highly affected if the package is used by CI systems running tests, since these systems typically don't retain the `PUB_CACHE` between test runs."
> — same page, line 37

> "The download count is not a perfect metric, and should only be regarded as an indicator of popularity."
> — same page, line 39

The tooltip on the package page states the window: **"Number of downloads of this package during the past 30 days"** (`pub-dev/app/lib/frontend/templates/_consts.dart:14-16`). The public API exposes the same field as `downloadCount30Days` (`pub-dev/doc/help-api.md:133`).

So, mechanically:

- **What is counted:** one increment per successful fetch of a package *archive* (`.tar.gz`) from pub.dev's server. Not a page view, not a like, not an install, not a unique device.
- **Window:** a rolling 30 days. It is **not** a since-publication total.
- **Granularity:** daily per version (`daily_download_counts/<date>/data-*.jsonl` with `per_version: [{version, count}]`, `pub-dev/app/lib/service/download_counts/sync_download_counts.dart:59-64`), stored for up to 731 days and aggregated into 30-day and weekly totals (`download_counts.dart:12-13,58-64`; `computations.dart:77,104-121`).

**Does it count a `pub get` of a package that is never used?** Yes. The counter increments when the archive is fetched; `pub get` fetches every archive in the resolved graph — direct, transitive, dev — regardless of whether any file imports it. It also counts `dart pub add`, `dart pub global activate`, and any direct archive fetch. It does **not** count resolution when the version is already in `PUB_CACHE` (hence the docs' "once per user per machine" and the CI caveat).

**Does it include CI/analysis bots and mirrors?** CI and build bots are named explicitly by the docs as an inflation source. Whether pub.dev's own analysis (`pana`) fetches count is **`unknown`** — the analysis pipeline reads the incoming upload bucket, not the public archive endpoint, so it *probably* does not count [INFERENCE]. **Mirrors are `unknown`**: pub.dev publishes no statement, and the upstream query that produces the daily counts is not in the open-source repo (only its JSON input schema is). A mirror that proxies the archive from pub.dev's server would count once per uncached fetch; a mirror that caches independently would not. Do not assert either way.

**Known data-quality history (primary source):** `sync_download_counts.dart:115-117` records that the query generating the counts "had a bug in the reg exp causing incorrect versions to be stored" before 2024-05-03. The pipeline is batch-processed, which is also why the API and the page disagree slightly (below).

## 1.2 What this package's number actually is (measured 2026-11-10)

| Measurement | Value | Source |
|---|---|---|
| Published | `2026-11-01T15:17:22Z` (9.3 days ago) | `https://pub.dev/api/packages/instant_barcode_scanner` |
| Versions on pub.dev | **only `0.2.0`** (no 0.1.0 is listed) | same |
| Page counter | **659 downloads** | `https://pub.dev/packages/instant_barcode_scanner` HTML |
| API counter | **619** (`downloadCount30Days`) | `https://pub.dev/api/packages/instant_barcode_scanner/score` |
| Likes | **0** | same |
| Pub points | **160/160** | same |
| Weekly buckets (newest first, newest date 2026-11-08) | **`[633, 26, 0, 0, …]`** | decoded from `data-weekly-sparkline-points` using pub-dev's `decodeIntsFromLittleEndianBase64String` (`pkg/_pub_shared/lib/format/encoding.dart`) |

Reading those numbers:

- Because the package is 9 days old, the "past 30 days" window **is** its entire lifetime. There is no pub.dev number that says "downloads since publication"; 659 and "all-time" coincide here by accident, not by definition.
- The two recorded values (659 page, 619 API) most likely differ because both are cached aggregates of a daily batch; the maintainer's "650" is consistent with either.
- 633 (week of 11-02…11-08) + 26 (11-01, the publication day, ~8.7 h) = 659 exactly. That is **≈3.0 downloads/hour on publication day and ≈3.8/hour for the following week** — flat, with no publish-era burst. Daily granularity is not public, so a sub-day spike cannot be excluded: **`unknown`**.
- 0 likes after 659 downloads is a 659:0 "engagement" ratio. For scale, `mobile_scanner` is 2 259 545:2 311 (≈978:1) and `google_mlkit_barcode_scanning` 155 319:158 (≈983:1). A package with genuine human users is expected to collect *some* likes; this one has none.

## 1.3 The comparison that settles it

Download counts are only meaningful against a cohort. I pulled a convenience sample of packages from `https://pub.dev/api/search?q=is:recent` (pages 1–8), resolved each package's **first** publication date and its 30-day count, and kept those ≤20 days old (`n = 44`):

| Cohort statistic (first published ≤20 days ago) | Downloads/day |
|---|---|
| p25 | 45 |
| **median** | **66** |
| p75 | 83 |
| full range | ≈8 – 120 |
| **this package (659 / 9.3 d)** | **≈71** |

This package is at the **median** for brand-new packages.

The cleanest control is a **same-day, same-shape package**: `streak_flame`, first published 2026-11-01T18:42Z, **one version**, **655 downloads**, 5 likes. `instant_barcode_scanner`: one version, 659 downloads, 0 likes. Five other packages first published that same day have 757–810 downloads. In other words, a package that nobody has heard of, with no releases after the first, tracks this one to within 1 %.

Established scanner packages for context (30-day counts): `mobile_scanner` 2 259 545; `google_mlkit_barcode_scanning` 155 319; `qr_code_scanner_plus` 90 832; `flutter_zxing` 56 767; `barcode_scan2` 19 022; `ai_barcode_scanner` 13 308; `scandit_flutter_datacapture_barcode` 8 356. This package is ~0.03 % of `mobile_scanner` and 40× below the smallest established alternative.

Caveats, stated rather than hidden: `is:recent` ordering may itself correlate with traffic [INFERENCE]; the sample is a convenience sample, not a random one; 30-day counts for a 9-day-old package are lifetime counts, which is why per-day normalisation is used; "downloads/day" is an upper bound on organic users.

## 1.4 Verdict

**The numeric claim is true and the implied meaning is false.** 650 is accurate as pub.dev's 30-day archive-download counter (659 at fetch; 619 in the cached API snapshot), and 9 days is the true age — but that counter is not users and does not count usage: it counts archive fetches, includes CI/bot/mirror traffic by pub.dev's own documentation, and for a brand-new package its value is dominated by the new-package baseline. **650 in 9 days is not evidence of organic demand**: at ≈71/day this package sits exactly at the median of 44 packages of comparable age, and a same-day single-version control package sits at 655 downloads. If the maintainer wants a real adoption signal, the questions pub.dev can answer are likes, verified publisher, and whether downloads *persist* after the "recent" boost ends; what would settle it is the cohort distribution above plus a re-measurement after day 30, when the rolling window starts dropping days. The ratio of downloads to likes (659:0) and the absence of any post-launch version bump are currently the strongest signals, and both are flat.

---

# Part 2 — Findings

A1 and A2 are **corrected** entries: the first audit's claims did not survive contact with the real repository. A3–A9 are quality/robustness; A10–A15 are polish. A3–A5 are deliberately deferred to a follow-up PR because they change behaviour, not CI.

## S1 — Corrected findings (release integrity and CI)

### A1. [Corrected] The release source and metadata are intact

**What the first audit claimed.** "The repository is not the package, and its metadata URL is dead": 0.2.0 source on no branch, `version: 0.1.0` on `main`, 404 metadata.

**What is true.** `schleunigst/instant_barcode_scanner` has `main` at `036f7f3` and tag `v0.2.0` (annotated `82e5a1d`); the tree is byte-identical to the published archive for every package file, and `homepage`, `repository` and `issue_tracker` all return HTTP 200. The original claim was an artifact of auditing a remote-less 0.1.0 dev checkout whose 0.1.0 pubspec names a different, dead org (`instantbarcode`). None of the three URLs shipped to consumers is broken.

**Residual risk (low).** The tag does not reproduce the published archive exactly: `example/lib/verify_main.dart` is untracked and `GeneratedPluginRegistrant.java` is generated, yet both are in the archive. Reproducibility rests on the archive sha256, not on the tag. Smallest fix: commit `verify_main.dart` (or delete it and note the change for the next release) and add a CI job that builds the archive from a clean checkout and compares its file list with the tag.

### A2. [Corrected] CI does compile Android; three gaps remain

**What the first audit claimed.** "CI never compiles the Android half of the plugin": only `flutter analyze`/`flutter test` on Ubuntu.

**What is true.** `.github/workflows/ci.yml` has three jobs. `test` runs format/analyze/test; `example` runs `flutter analyze`, `flutter test test`, `flutter build apk --debug` and `./gradlew :instant_barcode_scanner:assembleDebugAndroidTest` — so the 2 181 Kotlin lines are compiled twice and the instrumentation APK is assembled; `publish-check` runs `flutter pub publish --dry-run`. The first audit had read the dev checkout's stripped two-step workflow.

**Residual gaps (addressed on `ci/coverage-gaps`).** (1) `dart format` covered only `lib test`, so `example/` was unformatted by CI. (2) `publish-check` ran the dry-run but exited 0 on warnings. (3) Integration tests were assembled, never executed — no emulator job ran `flutter test integration_test`. These were process gaps, not missing compilation.

## S2 — Quality / robustness

### A3. `dispose()` cannot cancel an unanswered permission prompt, and can hang

**Evidence.** `InstantBarcodeScanner.dispose()` marks `_disposed` and then **enqueues** the platform call behind every earlier command (`lib/src/controller.dart:686-715`, queue at `:748-752`). A `scan()` whose drive is waiting for the runtime-permission prompt is exactly such a command (`driveTo` → `ensureCameraPermission()` suspends before taking the mutex, `InstantBarcodeScannerPlugin.kt:566-598`). The native `dispose()` that would cancel it (`InstantBarcodeScannerPlugin.kt:493-497`, `cancelPermissionRequest()` at `:560-564`) is therefore never reached while that prompt is up.

**Why it matters.** `await scanner.dispose()` can stay pending indefinitely if the user never answers the prompt (and a later controller's drive reports a spurious `permission_denied` because `permissionResume != null`, `:574-578`). This contradicts the documented guarantee: "awaiting dispose always guarantees teardown even when several callers race" (`controller.dart:683-685`). Whether Android delivers a denial when the activity is merely stopped is version/OEM dependent [INFERENCE]; activity destruction does resolve it via `onDetachedFromActivity` → `detachActivity` → `cancelPermissionRequest` (`:608-610,666-668`).

**Smallest fix.** Give cancellation its own pigeon method (`cancelPending()`), call it synchronously from `dispose()` before enqueuing the teardown, and have the pending `driveTo` complete with `permission_denied`/`cancelled`. Add a test with a held drive.

### A4. `analyzeImage()` decodes full-resolution bitmaps into ARGB_8888 — OOM risk

**Evidence.** `invertedInputImage()` calls `BitmapFactory.decodeFile(file.absolutePath)` with no `inSampleSize`, then allocates a second full-size `Bitmap.Config.ARGB_8888` and draws the first into it (`InstantBarcodeScannerPlugin.kt:425-490`). A 12 MP photo is ~48 MB per bitmap, 96 MB for the pair; a 48–200 MP phone photo is 200 MB–800 MB and will be killed on most devices. The non-inverted path (`InputImage.fromFilePath`, whose decode size ML Kit manages) is not affected — so enabling `invertImage: true` (a supported, documented feature for white-on-black symbols) changes a normal path into a crash path.

**Smallest fix.** Decode bounds first and pass an `inSampleSize` that caps the long edge at ~2048 px; reuse the same decoded bitmap where possible.

### A5. Preview rotation is derived from a deprecated, display-unaware API, on the wrong thread

**Evidence.** `publishPreviewMetrics()` reads `host.windowManager.defaultDisplay.rotation` (`InstantBarcodeScannerPlugin.kt:692-698`; deprecated since API 30). It is invoked from `CameraMechanism.openDevice` (camera thread, `CameraMechanism.kt:572`) and from `onConfigurationChanged`/`attachActivity`.

**Why it matters.** On Android 11+ multi-window, foldables, and non-default displays, `defaultDisplay` is not the display the activity is on; the PreviewMetrics rotation can be wrong, which the `InstantBarcodeScannerView` then applies literally (`lib/src/view.dart:73-81`). It also reads a `WindowManager` from the camera thread.

**Smallest fix.** On API 30+ use `activity.display?.rotation` (or `WindowManager.currentWindowMetrics`); post metric publication to the main looper.

### A6. The declared Flutter floor is unreachable and the SDK floor is unexplained

**Evidence.** `pubspec.yaml:18-20`: `sdk: ^3.13.5` together with `flutter: '>=3.3.0'`. Flutter 3.3 shipped Dart 2.18; no Flutter release satisfying `>=3.3.0` can satisfy Dart `^3.13.5` (Dart 3.13.x corresponds to Flutter ≈3.47). The Flutter constraint is therefore dead text, and it advertises a compatibility range the package cannot deliver. Nothing in the sources requires Dart 3.13: the newest language feature used is switch expressions (Dart 3.0).

**Why it matters.** Every consumer on Flutter 3.3–3.46 (i.e. essentially all stable users at publication time) is silently excluded, and `pana`'s platform/version analysis is given an inconsistent picture. The strictest possible floor is imposed with no stated justification.

**Smallest fix.** Set `sdk` to the real minimum (validated by CI) and either delete the `flutter:` floor or set it to the matching release (e.g. `flutter: '>=3.47.0'`). Add a CI matrix row on the oldest supported SDK.

### A7. The torch is a live-only control even though the native layer supports storing it

**Evidence.** `setTorch(true)` throws unless `state == live` (`lib/src/controller.dart:438-441,445-447`). The mechanism explicitly accepts the opposite contract: *"Torch is a live-only control; enabling it while not streaming stores it"* (`CameraMechanism.kt:219-221,230-233`). So the only way to light the lamp for a dark first scan is the constructor flag `ScannerConfig.torchEnabled` (`lib/src/platform/types.dart:303-304`).

**Why it matters.** For the stated use cases (checkout lanes, inventory walks, access points) the dark, low-light first scan is the common one; forcing "scan → wait for live → then call setTorch" means the first frame the user sees is unusable. There is also no auto-torch, tap-to-focus, focus-mode control or exposure compensation, so low light is entirely the host's problem.

**Smallest fix.** Allow `setTorch` while `parked`/`open`/`live` (the native side already stores it) and let it apply when streaming starts; document the resulting contract. Consider `autoTorch` on low luma as a later feature.

### A8. Public enums are exhaustive-switch traps: an additive enum value is a source-breaking change

**Evidence.** `BarcodeFormat` (`lib/src/platform/types.dart:7-22`) and `ScannerState` (`:402`) are exported (`lib/instant_barcode_scanner.dart:11-28`) and are exactly the kind of enum consumers switch over exhaustively. Adding `microQr`/`maxiCode` in a later 0.x release is "additive" in pub terms but breaks every exhaustive consumer `switch` at compile time. The same applies to `DetectionSpeed`, `CameraFacing`, `CameraLensType`, `BarcodeType`, `TorchState`.

**Why it matters.** The README promises "APIs may change between 0.x releases" (`README.md:43-44`), which covers it legally, but nothing warns implementers, and the package's own 0.2.0 already proves the hazard on the *platform* interface: `setEventHandlers` gained two **required** parameters (`lib/src/platform/platform.dart:20-25`) and `InstantBarcodeScannerPlatform` gained seven abstract methods, breaking any third-party test fake. `InstantBarcodeScannerPlatform` is exported, so those fakes are public API consumers.

**Smallest fix.** State the policy in the README ("these enums may gain values; always include a default branch"), and keep `InstantBarcodeScannerPlatform` internal (or give new members defaults) since only tests need it.

### A9. Non-Android failure is an opaque `channel-error`, not a documented unsupported-platform state

**Evidence.** The package declares only Android (`pubspec.yaml:34-39`) and the README says Android-only (`README.md:3`). On a platform with no registered handler, Pigeon 29 throws `PlatformException(code: 'channel-error', message: 'Unable to establish connection on channel …')` (`lib/src/pigeon/messages.g.dart:13-21`). The controller catches `PlatformException` and re-wraps it verbatim (`lib/src/controller.dart:204-206,224-226,254-262`), so `warmUp()`/`scan()` on iOS/macOS/Windows fail with `ScannerException` / `errorCode: 'channel-error'`.

**Why it matters.** The failure is at least typed (the earlier assumption that `MissingPluginException` escapes is wrong — verified in the generated code), but `channel-error` is a transport detail, indistinguishable from a broken channel on Android, and the README never states what a non-Android call does. A consumer building for both platforms must discover this by running.

**Smallest fix.** Map `channel-error` during `configure` to `ScannerException(state, 'unsupported_platform', ...)` and add one README sentence: "on non-Android platforms the first call fails with `unsupported_platform`; guard with `Platform.isAndroid`".

## S3 — Polish / documentation

### A10. The Android setup snippet omits the `uses-feature` opt-out
`README.md:306-312` tells consumers to add `<uses-permission android:name="android.permission.CAMERA" />`. Declaring `CAMERA` implies `android.hardware.camera` (and autofocus) as **required**, so Play filters out camera-less tablets/Chromebooks and devices where scanning is optional. The example app gets it right (`example/android/app/src/main/AndroidManifest.xml:2-3`) but the README does not show it. **Fix:** add `<uses-feature android:name="android.hardware.camera.any" android:required="false" />` to the snippet and explain the trade-off.

### A11. The changelog claims a 0.1.0 that was never published
`CHANGELOG.md:58` documents `## 0.1.0`, but pub.dev lists no 0.1.0 at all (`/api/packages/...` → `versions: ["0.2.0"]`), and `main`'s 0.1.0 is a different, unreleased tree. The 0.2.0 notes describe changes *relative to a release that consumers cannot obtain*. **Fix:** mark 0.1.0 as "never published", or drop the section and start the changelog at 0.2.0.

### A12. The dev checkout's README miscounts its tests
`repo@main:README.md:149` says "26 tests"; the suite runs 27 (`flutter test` → `+27: All tests passed!`). 0.2.0's README ("100 tests", `README.md:356`) is correct. This does not affect the published package (whose README says 100, matching the suite). **Fix:** generate the count or drop the number.

### A13. Notifiers and listeners are never disposed
`dispose()` closes the two stream controllers but leaves `_status`, `_textureId`, `_previewMetrics`, `_analysisMetrics`, `_torchState`, `_zoomScale` alive forever (`lib/src/controller.dart:62-73,702-714`); a host that adds listeners and forgets to remove them after dispose keeps them alive for the app's lifetime. **Fix:** dispose the notifiers in the `finally` block (breaking only for post-dispose listeners, which are already undefined).

### A14. The example asks for permission twice
`example/lib/main.dart:79-90` requests `CAMERA` via `permission_handler` in `initState`'s path, and the plugin also requests it on the first drive (`InstantBarcodeScannerPlugin.kt:566-598`; README admits both at `:314-317`). Two request paths on the same permission can race (the second sees `permissionResume != null` and reports denial). **Fix:** drop `permission_handler` from the example and let the plugin own it, or request once and configure the example to skip the plugin path.

### A15. `dispose()`-mid-scan behaviour is documented only in dartdoc
The `StateError` contract for a pending `scan()` exists in `controller.dart:680-700` and is tested (`test/hardening_test.dart:267-343`, `test/controller_test.dart:424`), but the README's usage section (`README.md:62-100`) never mentions it, nor what happens to a scan when the app is backgrounded (the camera is closed and the pending scan fails). **Fix:** two sentences in the README's lifecycle section.

## What is genuinely good (so the review is not one-sided)

- The core idea is real and implemented, not marketed: `parked` keeps device + session and merely stops repeating (`CameraMechanism.kt:754-786,809-825`), and `closed` waits for the HAL availability callback (`InstantBarcodeScannerPlugin.kt:246-296`, `CameraSelection.kt:135-163`) — this is the claimed differentiator and it is correctly built.
- Single-flight convergence with retargeting, step timeouts (`CameraMechanism.kt:346-438,484-511`), generation-tagged decode results (`BarcodeAnalysisPipeline.kt:230-252`), and a permission-denied error code (`InstantBarcodeScannerPlugin.kt:239-245`) are all present and coherent.
- The Dart suite is real: 100 tests with a fake that models async ordering, race and held-drive behaviour (`test/fake_platform.dart`, `controls_test.dart`, `hardening_test.dart`), and `flutter analyze` is clean with `flutter_lints` 6.
- `rawBytes` pass-through, the unmodifiable `formats` snapshot (`types.dart:276-291`) and the honest `Limitations` section are above the median for 0.x packages.

---

## 3. Toolchain results (recorded 2026-11-10; long dependency lists condensed)

### 3.1 Repository `main` @ `036f7f3` (publish checkout) — `flutter 3.47.8` / `Dart 3.13.7`

```
$ flutter analyze
Analyzing instant_barcode_scanner...
No issues found! (ran in 5.7s)                       # exit 0

$ flutter test
...
00:01 +100: All tests passed!                        # exit 0, 100 tests

$ dart format --output=none --set-exit-if-changed <21 tracked .dart files>
Formatted 21 files (0 changed) in 0.09 seconds.     # exit 0
# NB: example/lib/verify_main.dart is untracked and unformatted; CI never sees it.

$ cd example && flutter build apk --debug
Running Gradle task 'assembleDebug'...
✓ Built build/app/outputs/flutter-apk/app-debug.apk  # exit 0, 84.9 s

$ dart pub publish --dry-run   (gate: fail if "Package has N warnings", N>0)
Total compressed archive size: 147 KB.
Package has 0 warnings.                              # gate PASS
```

`dart pub outdated` in this checkout: direct and dev dependencies are up-to-date; only
transitive rows are behind (5 upgradable rows are locked, e.g. analyzer 14.5.0→14.7.0,
crypto 3.0.7→3.0.8, built_collection 5.1.2→6.0.0, test_api 0.7.12→0.7.15).

### 3.2 Published 0.2.0 archive (extracted pristine, same toolchain)

```
$ flutter analyze
Analyzing pub020...
No issues found! (ran in 19.2s)                      # exit 0
```

```
$ flutter test
...
00:03 +100: All tests passed!                        # exit 0, 100 tests
```

```
$ dart pub outdated
direct dependencies: all up-to-date.
dev_dependencies: all up-to-date.
transitive: material_color_utilities 0.13.0→0.13.1 (locked)
transitive dev: built_collection, test_api (locked)
all dependencies are up-to-date.
```

```
$ dart format --output=none --set-exit-if-changed lib test
Formatted 17 files (0 changed) in 0.07 seconds.     # exit 0
```

```
$ dart pub publish --dry-run
Total compressed archive size: 147 KB.
Package has 0 warnings.                              # exit 0
```

No analyzer warnings, no info-level lints, no publish warnings in either tree. The code is lint-clean; the defects above are behavioural and structural, which is why they do not appear in this output. Note that `flutter analyze` does **not** compile Kotlin, so none of the 2 181 Kotlin lines is validated by any of these four commands.

## 4. CI assessment (real workflow, `main` @ `036f7f3`)

| Question | Answer |
|---|---|
| Analyze/test on PRs? | Yes — `pull_request` + `push`, `test` job runs format/analyze/`flutter test`. |
| Format check? | Yes, `test` job. It covered `lib test` only; this PR extends it to `example/lib example/test example/integration_test`. |
| Android build? | Yes — `example` job runs `flutter build apk --debug` and `./gradlew :instant_barcode_scanner:assembleDebugAndroidTest`, so the Kotlin and the instrumentation APK are compiled. |
| Publish validation? | Yes — `publish-check`; this PR makes it fail when the dry-run reports warnings (the version hint is still allowed). |
| Device or host only? | Host for the three existing jobs. This PR adds `android-instrumented`, which boots an API-34 emulator and runs the 4 instrumented Kotlin tests (`connectedDebugAndroidTest`). `flutter test integration_test` was attempted first and hangs on a hosted emulator (17+ min, no output), so it stays a documented follow-up. |
| Push triggers | Every branch and every PR, with `concurrency` cancel-in-progress. |
| Coverage / docs | None. |

The three residual gaps were process gaps. Format scope and warning enforcement are
closed by the CI PR; device execution is now covered by the instrumented Kotlin tests,
while the Dart integration suite remains unautomated because it hangs on a hosted
emulator (camera + permission handshake).

**Observed on PR #22 (not fixed here):** the workflow triggers on both `push` and
`pull_request`, so a branch PR runs every job twice — 8 jobs for 4 contexts, including
two emulator boots. A `push: branches: [main]` filter (or a concurrency group keyed on
the PR number) would halve CI cost.

**Runner finding from PR #22:** the first `android-instrumented` runs failed before
reaching the tests — the runner exposed `/dev/kvm` without granting the runner user
access (`ProbeKVM: This user doesn't have permissions to use KVM`), so the x86_64
emulator booted in software (611–679 s) and the action either died on an adb broken pipe
or ran past 20 minutes. Pinning `ubuntu-24.04` alone did not help; the job now applies
the android-emulator-runner README's documented udev rule (`MODE="0666"` on
`/dev/kvm`) before boot. This is an environment constraint, not a package defect.

## 5. Ranked roadmap (≤10, with effort)

| # | Action | Fixes | Effort |
|---|---|---|---|
| 1 | Commit `example/lib/verify_main.dart` (or drop it) and add a CI check that the published archive is reproducible from a clean tag checkout | A1 residual | **S** |
| 2 | Close the CI gaps: format `example/`, fail `publish-check` on warnings, execute device tests on an emulator (Kotlin instrumentation; the Dart integration suite still needs a camera-capable harness) | A2 | **S** (this PR) |
| 3 | Give pending permission prompts a cancellation path that is not queued behind the drive; test with a held drive | A3 | **S–M** |
| 4 | Downsample still images before inversion (cap long edge ~2048) | A4 | **S** |
| 5 | Use `activity.display` / window metrics on API 30+; publish metrics on the main thread | A5 | **S** |
| 6 | Correct `environment:` (SDK floor = real minimum; Flutter floor consistent) and add an old-SDK CI row | A6 | **S** |
| 7 | Allow `setTorch` while parked/open/live (native already stores it); document low-light guidance and add `autoTorch` as a follow-up | A7 | **S–M** |
| 8 | Publish the enum-growth policy; make `InstantBarcodeScannerPlatform` internal or add defaults to new members | A8 | **S** |
| 9 | Map `channel-error` to `unsupported_platform`; add `Platform.isAndroid` guidance | A9 | **S** |
| 10 | Docs/CHANGELOG pass: `uses-feature` snippet, "0.1.0 never published", dispose-mid-scan and background scan behaviour, test-count drift, dispose notifiers, single permission request in the example | A10–A15 | **S** |

Items 3–5 change behaviour and are deliberately not part of the CI PR.

## 6. Unknowns and inference register

- **`unknown`**: the exact upstream query/log source that produces `daily_download_counts` (not in the open-source pub-dev repo); whether pub.dev's own analysis fetches count; whether any mirror's fetches count; per-day download counts for this package (pub.dev exposes only weekly buckets and a 30-day total); the reason for `sdk: ^3.13.5`.
- **[INFERENCE]**: the `is:recent` sample may be biased toward packages with traffic; `pana` fetches probably do not hit the counted archive endpoint; the A3 prompt/Android-dismissal interleaving is version-dependent; the release was published from a dirty working tree (inferred from the two archive-only files).
- **Not verified:** device behaviour on real hardware — no physical device was attached, so every camera2/ML Kit claim is static reading plus the repository's own recorded measurements. For the new emulator job, local validation was attempted with the WSL2 `pixel_bench` AVD; the emulator process dies mid-run (`adb: no devices/emulators found`), so only the GitHub-hosted CI run is authoritative for the integration-test path.
