# Contributing to instant_barcode_scanner

## Branch model

| Branch            | Role                                                                      |
| ----------------- | ------------------------------------------------------------------------- |
| `main`            | Releasable. Only release merges and hotfixes land here.                   |
| `develop`         | Integration branch. Default base for feature work; must stay green.       |
| `feat/<slug>`     | One feature or change, branched from `develop`.                           |
| `fix/<slug>`      | One fix, branched from `develop`.                                         |
| `chore/<slug>`    | Tooling, documentation, or maintenance work.                              |
| `release/<x.y.z>` | Cut from `develop` for stabilization; merged to `main` and tagged.        |

Open feature, fix, and chore pull requests against `develop`. Keep branches
short-lived and delete them after merging.

## Quality gates

Run from the package root (`. ~/.flutter-env` in the project environment):

```sh
dart run pigeon --input pigeons/messages.dart   # only after editing pigeons/messages.dart
flutter analyze                                  # must be clean
flutter test                                     # all green
cd example && flutter build apk --debug          # for Kotlin/Gradle changes
```

- Generated Pigeon files (`lib/src/pigeon/messages.g.dart`,
  `android/src/main/kotlin/.../pigeon/Messages.g.kt`) are committed; never
  hand-edit them.
- Device and instrumentation verification is required for changes touching
  the camera mechanism: state convergence, latency, and indicator truthfulness
  need a real camera, not just an APK build.
- For release builds, verify the R8/proguard path, not only `--debug`.

## Commits

- Use an imperative subject line and a scoped body explaining *why*.
- Reference issue or pull-request IDs where applicable.
- Keep one concern per commit where practical.

## Review

- Pull requests are reviewed in place. Keep design context in the pull request
  or linked issue rather than in a separate internal document.
- Every behavioral fix lands with a regression test. Kotlin behavior is tested
  through the Dart platform fake where possible and on-device otherwise.
- Reviews focus on truthful camera release, lifecycle ordering, error
  propagation, and API compatibility.

## CI

CI runs on every push and pull request (`.github/workflows/ci.yml`):

- `test`: formatting, `flutter analyze`, and the Dart test suite.
- `example`: example analysis/tests, a Gradle debug build, and compilation of
  the instrumented-test APK.
- `publish-check`: `flutter pub publish --dry-run`, so package metadata cannot
  rot silently.

Integration tests need a camera and are run manually. See `README.md` for the
commands.

## Maintenance

- Dependabot proposes pub, Gradle, and GitHub Actions updates. Merge once CI is
  green; treat ML Kit and Gradle plugin bumps as behavior changes.
- Keep the README scope statement accurate. Decline features that would turn
  this into a general camera package.
- New Flutter stable releases surface first in CI; use those runs as the
  upgrade signal.

## Releases

1. Branch `release/<version>` from `develop`.
2. Bump `pubspec.yaml`, update `CHANGELOG.md`, and stabilize on the branch with
   the gates above plus a release-mode APK and device pass.
3. Optionally run `dart pub global activate pana && pana --exit-code` before
   tagging.
4. Merge to `main`, tag `vX.Y.Z`, and publish with `dart pub publish`.
5. Merge `main` back into `develop`.
