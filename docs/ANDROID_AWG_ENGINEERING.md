# Android AWG/Tailscale engineering build

The optional `LXBOX_LIBBOX_AAR` environment variable selects a local engineering
AAR for Gradle. It must be an absolute readable `.aar` path; invalid overrides
fail the build. Without it the ordinary published AAR and
`app/android/libbox.version` remain authoritative. No binary is committed here. The source snapshot helper includes tracked Git
changes only, so untracked local profiles and device reports are excluded.

## Reproducible build

Use the core's [AWG feature](https://github.com/Leadaxe/sing-box-lx/tree/lx/SPECS/FEATURES/019-TAILSCALE_AWG)
and task149 bootstrap to construct a new workspace from pinned dependencies and
patches. Supply that workspace explicitly; older local workspaces are not reused
implicitly. Run from the LxBox checkout:

```sh
export LXBOX_AWG_CORE="$(cd ../sing-box-lx && pwd)"
export LXBOX_AWG_GOWORK="$(cd ../awg-workspace && pwd)/go.work"
export LXBOX_AWG_OUT="$(pwd)/../engineering-artifacts/android-arm64"
./scripts/build-tailscale-awg-android.sh aar
./scripts/build-tailscale-awg-android.sh apk
```

Choose a fresh output directory for changed inputs. Override the candidate's
version with `LXBOX_AWG_CORE_VERSION` when needed. The default is derived from
the checked-out core revision and labels the result as an engineering artifact.
The script pins Go1.26.10, SagerNet gomobile0.1.12 and NDK28.2.13676358. Use
`LXBOX_AWG_AAR_JAVA_HOME` for JDK17, `LXBOX_AWG_APK_JAVA_HOME` for JDK21,
`LXBOX_AWG_NDK`, `LXBOX_AWG_FLUTTER` and `ANDROID_HOME` for installed tools.
It does not install SDKs, change the host Java default, install an APK or start a
VPN. Run the normal Flutter dependency bootstrap before the APK stage.

The opt-in core flag is `-with-tailscale-awg`. The script requests Android arm64
and the modern API24 variant explicitly. Other ABIs and AAB acceptance are later
gates. Output includes AAR/APK manifests, API/ABI and signature metadata, build
logs and `SHA256SUMS`. These locally generated manifests may contain local build
paths and signing fingerprints; review them before sharing. Keep private test
profiles and device captures outside the source tree.

## Compatibility contract

`getCoreCapabilities` returns compiled `with_tailscale_awg` evidence through the
existing MethodChannel. Old AARs, missing methods and probe failures return false;
there is no inference from a version string. Missing capability rejects atomic
AWG application instead of silently removing its profile.

The existing Tailscale stream and unary status paths accept optional
`configured_mode`, `applied_mode`, `profile_id`, `profile_fingerprint`, `applied`
and safe `last_error` transport fields. Missing optional native API yields no
transport object. Applied transport status is distinct from peer reachability.
The single `BoxVpnService`, socket protection and per-node state directories
remain the platform boundary.

AWG2 and AWG3 peers require matching compatible profiles. Family3 carries
AWG3.1 parameters; Headscale and DERP do not need an AWG fork. Profiles may include
shared obfuscation key material, but export never transfers machine identity.

## Validation and teammate testing

Run whole-project `flutter analyze` and task-related named tests. Test capability
failure, profile import/edit/export, marker3 backups, protected CIDR/private DNS,
raw mixin coexistence and network identity replacement. Full suites run in CI.

For in-place physical testing, verify the existing application's signer before
installing a compatible debug APK with `adb install -r`. A differently signed
installation requires its matching distribution channel to preserve data.
Android VPN consent remains a normal on-device confirmation.

[Task700](spec/tasks/700-tailscale-awg-android.md) defines isolated direct/DERP,
VLESS, failure, identity and lifecycle acceptance. [Task701](spec/tasks/701-awg2-derp-stability.md)
defines large-transfer and network-recovery evidence. Mobile handoff, background
behavior, remaining ABIs and Windows/macOS acceptance remain explicit gates.
