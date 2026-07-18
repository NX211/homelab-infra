# capturly-android-runner

Custom GitHub Actions runner image for **Capturly Android release builds**, run on
homelab compute via Actions Runner Controller (ARC). Extends
`ghcr.io/actions/actions-runner` with the app's exact toolchain (JDK 17, Android
SDK 36 / build-tools 36.0.0 / NDK 28.2.13676358, Node 22, pnpm, ccache) so the
ephemeral runner pod is the full build environment.

- **Built + pushed by** `.github/workflows/build-capturly-android-runner.yml` →
  `ghcr.io/nx211/capturly-android-runner`.
- **Consumed by** the `arc-runners-android` scale set
  (`argocd/applications/arc-runners-android.yaml`), which only the trusted
  `release-android` workflow in `capturly.app` targets via `runs-on: homelab-android`.

Toolchain versions are pinned to `apps/mobile/android/build.gradle` in the
`capturly.app` repo — bump this image when those change. See
`docs/runbooks/capturly-android-arc-runner.md` for setup, rotation, and the
SOC 2 control notes.
