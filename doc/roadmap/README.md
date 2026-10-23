# Roadmap: Android parity, beyond, then iOS

This directory is the working memory for a long-horizon program. Read this
file first; it defines the phases, the gates, and how work is delegated.

## Mission

`instant_barcode_scanner` exists because mobile barcode scanning is usually
slow for a structural reason: the camera is opened, configured, started and
torn down around every read. This package keeps a warm session (parked camera,
configured session) and closes truthfully when the app is done.

The next program of work has three phases, in order:

1. **Harden v0.1 on Android** — find and fix latent lifecycle bugs in the
   shipped design. (Complete; see `01-android-audit-2026-10-22.md`.)
2. **Feature parity with `mobile_scanner` on Android** — the API a team
   actually needs to replace `mobile_scanner`, mapped onto our warm-session
   model, without giving up truthful close. See `02-parity-matrix.md`.
3. **Beyond parity** — improvements `mobile_scanner` does not have, once
   parity is real. See `03-beyond-parity.md`.
4. **iOS** — the same package, same public API, AVFoundation underneath.
   Constraints and open experiments are in `04-ios-constraints.md`.

The user has directed that the package repository stays **private** for now.
Publishing (pub.dev, tag `v0.1.0`/later) is a separate, later decision. The
blog remains a separate publication track.

## Non-negotiable principles

- **Truthful completion.** A future completing after `await close()` means
  the camera device is released and the OS will not report a camera in use.
  A closed snapshot after an NFC handoff additionally means the camera HAL
  reports the device available. Nothing in parity work may weaken this; new
  features must degrade to a truthful state when unsupported.
- **One public API, two platforms.** New API must be expressible on
  AVFoundation, even where Android ships first. Android-only knobs
  (`invertImage`, `autoZoom`, `cameraResolution`) must be explicit and
  capability-negotiated, never silently ignored.
- **The controller owns lifecycle.** No hidden `autoStart`; the app (or
  widget) calls `warmUp`/`park`/`close`/handoff. Parity adds *configuration*
  and *controls*, not a second lifecycle model.
- **No comments that lie.** If behavior differs from a doc comment, the
  behavior or the comment is a bug. The v0.1 review doc
  (`doc/reviews/2026-10-17-v0.1-initial.md`) is the contract baseline.
- **Every fix lands with a regression test.** Pure-Kotlin behavior is tested
  through the Dart fake when possible and on-device otherwise.

## Current position

As of 2026-10-22:

- v0.1 Android audit complete; 15 hardening tests added (`test/hardening_test.dart`),
  full suite 66 green, `flutter analyze` clean, debug APK builds.
- Kotlin audit fixes K1/K5/K6 landed (availability watch ordering, ML Kit
  client race, safe `ImageProxy.close`).
- Parity specification drafted in `02-parity-matrix.md`; no parity code has
  started.
- iOS has no implementation yet; the design paper commits to this package
  owning it eventually. Do not publish 1.0 before the iOS story is decided.

## Phase plan and gates

| Phase | Scope | Gate |
| --- | --- | --- |
| 0 (done) | Audit + harden Android v0.1 | analyze clean, suite green, APK builds, findings recorded |
| 1 | Parity spec review: final API shape for tranches A–C | user sign-off on `02-parity-matrix.md` API deltas |
| 2 (A) | Core controls: facing/lens/camera selection, torch, zoom, formats | analyze + tests + instrumented run on `pixel_bench`; README updated |
| 3 (B) | Detection behavior: timeout/throttle, dedupe, multi-barcode batches, scan window, image return/invert, analyzeImage | same + battery sanity on device |
| 4 (C) | View parity: aspect/crop/fit, overlay/placeholder/error handling, tap-to-focus | same + visual check in `example/` |
| 5 | Beyond-parity candidates (`03-beyond-parity.md`) | user priorities; each candidate gets its own SDD |
| 6 | iOS implementation to parity + warm-session contract | unit + on-device iOS; capabilities matrix truthful |
| 7 | Packaging/release | pub dry-run 0 warnings, pana, human checklist in research repo |

Phase 2 starts only after Phase 1 is signed off. Phase 5 does not start
before Phase 2–4 are complete (the user's ordering), even though candidates
are collected earlier.

## Working agreement (SDD)

For each tranche, produce a short spec before code:

1. **Context** — what exists (files, API, tests), what the platform offers.
2. **Contract delta** — exact public API additions/changes, error codes,
   capability entries, README paragraph.
3. **State machine delta** — which states/commands are affected; must include
   idle-policy and handoff interactions.
4. **Test plan** — Dart unit (fake), Kotlin unit/instrumented, on-device
   checks, battery check where relevant.
5. **Rollout/rollback** — additive API only; old behavior preserved.

Keep the spec in a PR/commit note or append it to the parity doc. Do not
delegate implementation without the spec.

### Subagent brief template

Subagents start fresh: they know nothing. Give them:

- The repository path (`/home/admin/projects/instant_barcode_scanner`), branch
  (`refactor/native-structure`), and the fact that `/home/admin/projects/publish/`
  copies are **not** the working tree.
- The exact files to read (list them), the contract doc, and this roadmap.
- Commands: `. ~/.flutter-env` first; `flutter analyze`; `flutter test`;
  build from `example/` (`flutter build apk --debug`).
- Constraints: no new dependencies without asking; no lifecycle redesign;
  truthful close; style of surrounding code; no comments unless value-adding.
- The deliverable: a report in the final message (not only files), with
  findings, spec delta, and verification evidence. **Audits must return the
  findings table in the message** — a prior Kotlin audit subagent returned an
  empty report twice and its work was redone directly.
- For device work: emulator `pixel_bench` (Pixel 8, API 35) may be down;
  `adb devices` can be empty. Rebuild the x86_64-only APK after fat APKs.

## Risk register

| Risk | Impact | Mitigation |
| --- | --- | --- |
| Camera2 has no `CameraX` conveniences (autoZoom, lens cycling, focus) | parity work is bigger than "wire the API" | implement against `CameraCharacteristics`; keep API behavior documented; instrumented tests |
| Logical multi-camera devices expose odd IDs | lens selection picks wrong physical camera | rank by focal length + facing; allow explicit camera id later |
| Scan-window/rotation differences across devices | false negatives | filter by mapped corners only after instrumented validation |
| Permission flow on Android missing (K3) | first-run parity gap; `SecurityException` today maps to generic failure | add `permissionDenied` error code + activity result plumbing in tranche A |
| iOS cannot park a session without camera indicator | `supportsPark=false` on iOS | warmUp degrades to open; measure stop/start cost before promising |
| Scope creep into a general camera package | schedule blow-up | parity matrix is the boundary; beyond-parity items get prioritized separately |
| Package/repo visibility confusion | accidental publish | repo private; publish is a human-gated checklist |

## Document index

- `01-android-audit-2026-10-22.md` — findings, fixes, deferred items with
  locations.
- `02-parity-matrix.md` — `mobile_scanner` 7.4.2 inventory, gap matrix, API
  deltas, tranche plans, Android implementation notes.
- `03-beyond-parity.md` — candidate improvements, criteria, parking lot.
- `04-ios-constraints.md` — AVFoundation mapping and experiments to run.
