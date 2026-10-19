# Working strategy

## Branch model

| Branch            | Role                                                                               |
| ----------------- | ---------------------------------------------------------------------------------- |
| `main`            | Releasable. Only release merges and hotfixes land here. Every commit passes gates. |
| `develop`         | Integration. Default base for feature work; must stay green.                       |
| `feat/<slug>`     | One feature/change, branched from `develop`.                                       |
| `fix/<slug>`      | One fix (e.g. `fix/review-findings`), branched from `develop`.                     |
| `chore/<slug>`    | Tooling/docs/maintenance work.                                                     |
| `release/<x.y.z>` | Cut from `develop` for stabilization; merged to `main` and tagged.                 |

- Short-lived branches merge back into `develop` (merge commit or rebase,
  either is fine) and are deleted after.
- `main` only ever advances by merging a `release/*` branch (or a
  `hotfix/*` taken from `main`), then gets a `vX.Y.Z` tag.
- Docs-only changes may land on `develop` directly.
- Review baseline tags use `vX.Y.Z-dev.N` (first: `v0.1.0-dev.1`).

Once a GitHub remote exists, the same flow moves to PRs: `feat/*`/`fix/*` →
`develop`, `release/*` → `main`, with the same quality gates required in CI.

## Quality gates (before merging into `develop`/`main`)

Run from the package root (`. ~/.flutter-env` in this environment):

```sh
dart run pigeon --input pigeons/messages.dart   # only after editing pigeons/messages.dart
flutter analyze                                  # must be clean
flutter test                                     # all green
cd example && flutter build apk --debug          # for any Kotlin/Gradle change
```

- Generated pigeon files (`lib/src/pigeon/messages.g.dart`,
  `android/src/main/kotlin/.../pigeon/Messages.g.kt`) are committed; never
  hand-edit them.
- Device/instrumentation verification is required for changes touching the
  camera mechanism (state convergence, latency, indicator truthfulness),
  not just the APK build.
- For release builds, verify the R8/proguard path (consumer rules), not only
  `--debug`.

## Commits

- Imperative subject line, scoped body explaining *why*.
- Reference review findings by ID where applicable (e.g. `Fixes R1, R2`).
- One concern per commit where practical.

## Review workflow

- Critical reviews are PR-style and persisted under `doc/reviews/` with the
  baseline commit, findings (severity, file:line, impact, fix), and a
  disposition table that gets updated as findings are fixed
  (`open` → `fixed in <commit>`).
- Current open review: `doc/reviews/2026-10-17-v0.1-initial.md`.

## CI

If a GitHub remote exists, CI runs on every push and PR (`.github/workflows/ci.yml`):

- `test` job: format check, `flutter analyze`, `flutter test` (unit).
- `example` job: example's analyze/tests, a Gradle `assembleDebug` build,
  and a compile of the instrumented-test APK
  (`assembleDebugAndroidTest`) — so native, Gradle, and instrumented-test
  breakage is caught without a device.
- `publish-check` job: `flutter pub publish --dry-run`, so publishing
  metadata (README, LICENSE, changelog, size) cannot rot silently.

The integration (device) tests cannot run in CI — they need a real camera.
For changes touching the camera mechanism, run them manually as the gates
above require; they are the one part of the green build that CI cannot
replace.

## Maintenance

- Dependabot opens PRs for pub, Gradle, and GitHub Actions versions (weekly
  for pub/actions, monthly for Gradle). Merge them once CI is green; review
  ML Kit or Gradle plugin bumps like any dependency change, since they can
  change device behavior.
- Keep the README's scope statement true. If a requested feature would grow
  the surface, decline it in the issue rather than merging it
  half-thought-through — the maintenance story depends on staying small.
- When Flutter moves (new stable channel), CI's unpinned stable channel will
  surface the breakage first; treat those runs as the upgrade signal.

## Releases

1. Branch `release/<version>` from `develop`.
2. Bump `pubspec.yaml` version, update `CHANGELOG.md` (new top section, no
   unpublished entries left under the old one); stabilize on the branch
   (gates above, plus a release-mode APK and device pass).
3. Optional but recommended: `dart pub global activate pana && pana
   --exit-code` before tagging, so the pub.dev score surprises won't.
4. Merge to `main`, tag `vX.Y.Z`, publish with `dart pub publish`.
5. Merge `main` back into `develop`.
