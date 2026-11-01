#!/usr/bin/env bash
# Task 700: local engineering artifacts only. Never fetch/replace the production AAR.
set -euo pipefail

ACTION="${1:-}"
case "$ACTION" in aar|apk) ;; *) echo "usage: $0 aar|apk" >&2; exit 2 ;; esac
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CORE_ROOT="${LXBOX_AWG_CORE:-$(dirname "$REPO_ROOT")/sing-box-lx}"
AWG_GOWORK="${LXBOX_AWG_GOWORK:-}"
ARTIFACT_ROOT="${LXBOX_AWG_OUT:-$(dirname "$REPO_ROOT")/artifacts/tailscale-awg/android-arm64-$(date -u +%Y%m%d)}"
CORE_BASE_VERSION="$(git -C "$CORE_ROOT" describe --tags --always 2>/dev/null || echo engineering)"
CORE_VERSION="${LXBOX_AWG_CORE_VERSION:-${CORE_BASE_VERSION#v}-awg149.engineering}"
GO_TOOLCHAIN="${LXBOX_AWG_GO_TOOLCHAIN:-go1.26.10}"
ANDROID_SDK="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-$HOME/Android/Sdk}}"
FLUTTER_ROOT="${LXBOX_AWG_FLUTTER:-$HOME/.cache/lxbox-flutter-3.47.1}"
mkdir -p "$ARTIFACT_ROOT/evidence"
ARTIFACT_ROOT="$(cd "$ARTIFACT_ROOT" && pwd)"

if [[ "$ACTION" == aar ]]; then
    [[ -n "$AWG_GOWORK" && -f "$AWG_GOWORK" ]] || { echo "Set LXBOX_AWG_GOWORK to a pinned workspace produced by the core bootstrap" >&2; exit 1; }
    export JAVA_HOME="${LXBOX_AWG_AAR_JAVA_HOME:-/usr/lib64/jvm/java-17-openjdk}"
    export ANDROID_HOME="$ANDROID_SDK"
    export ANDROID_NDK_HOME="${LXBOX_AWG_NDK:-$ANDROID_SDK/ndk/28.2.13676358}"
    [[ -x "$JAVA_HOME/bin/java" && -f "$ANDROID_NDK_HOME/source.properties" ]] || {
        echo "Set LXBOX_AWG_AAR_JAVA_HOME (JDK17) and LXBOX_AWG_NDK to installed toolchains" >&2; exit 1;
    }
    export PATH="$JAVA_HOME/bin:$ARTIFACT_ROOT/tools:$PATH"
    mkdir -p "$ARTIFACT_ROOT/tools"
    # Pin the generator as well as the Go compiler. Do not replace global Go tools.
    GOWORK=off GOTOOLCHAIN="$GO_TOOLCHAIN" GOBIN="$ARTIFACT_ROOT/tools" \
        go install github.com/sagernet/gomobile/cmd/gomobile@v0.1.12 github.com/sagernet/gomobile/cmd/gobind@v0.1.12 \
        > "$ARTIFACT_ROOT/evidence/mobile-tools.log" 2>&1
    (
        cd "$CORE_ROOT"
        GOTOOLCHAIN="$GO_TOOLCHAIN" GOWORK="$AWG_GOWORK" CGO_ENABLED=1 \
            go run ./cmd/internal/build_libbox -target android -platform android/arm64 \
            -android-variant modern -with-tailscale-awg -version "$CORE_VERSION" \
            -output-dir "$ARTIFACT_ROOT" -mobile-bin "$ARTIFACT_ROOT/tools"
    ) > "$ARTIFACT_ROOT/evidence/aar-build.log" 2>&1
    python3 - "$CORE_ROOT" "$AWG_GOWORK" "$ARTIFACT_ROOT" "$GO_TOOLCHAIN" "$CORE_VERSION" <<'PY'
import hashlib, json, os, pathlib, subprocess, sys, zipfile
core, workspace, output, toolchain, version = sys.argv[1:]
output = pathlib.Path(output)
aar = output / 'libbox.aar'
with zipfile.ZipFile(aar) as z:
    abis = sorted(n for n in z.namelist() if n.startswith('jni/') and n.endswith('.so'))
    if not abis or any(not n.startswith('jni/arm64-v8a/') for n in abis):
        raise SystemExit('AAR ABI boundary failed: expected arm64-v8a only')
    (output/'classes.jar').write_bytes(z.read('classes.jar'))
metadata = {
    'task': 700, 'kind': 'engineering; not a published release pin',
    'core_base_revision': subprocess.check_output(['git', '-C', core, 'rev-parse', 'HEAD'], text=True).strip(),
    'core_has_uncommitted_changes': bool(subprocess.check_output(['git', '-C', core, 'status', '--porcelain'], text=True)),
    'core_version': version, 'go_toolchain': toolchain,
    'gomobile': 'github.com/sagernet/gomobile@v0.1.12',
    'ndk': pathlib.Path(os.environ['ANDROID_NDK_HOME']).name,
    'java_home': os.environ['JAVA_HOME'], 'go_workspace': workspace,
    'go_workspace_sha256': hashlib.sha256(pathlib.Path(workspace).read_bytes()).hexdigest(),
    'production_aar_replaced': False, 'production_pin_changed': False,
    'aar_sha256': hashlib.sha256(aar.read_bytes()).hexdigest(), 'native_libraries': abis,
    'device_acceptance': 'not executed',
}
(output/'AAR-MANIFEST.json').write_text(json.dumps(metadata, indent=2)+'\n')
PY
    "$JAVA_HOME/bin/javap" -classpath "$ARTIFACT_ROOT/classes.jar" \
        io.nekohasekai.libbox.TailscaleTransportStatus io.nekohasekai.libbox.TailscaleEndpointStatus \
        io.nekohasekai.libbox.Libbox > "$ARTIFACT_ROOT/evidence/aar-api.txt"
    grep -q 'tailscaleAWGSupported' "$ARTIFACT_ROOT/evidence/aar-api.txt"
    grep -q 'getTransport' "$ARTIFACT_ROOT/evidence/aar-api.txt"
else
    [[ -f "$ARTIFACT_ROOT/libbox.aar" && -f "$ARTIFACT_ROOT/AAR-MANIFEST.json" ]] || {
        echo "Run the aar stage first in LXBOX_AWG_OUT" >&2; exit 1;
    }
    python3 - "$ARTIFACT_ROOT" <<'PY'
import hashlib, json, pathlib, sys
p = pathlib.Path(sys.argv[1]); m = json.loads((p/'AAR-MANIFEST.json').read_text())
if hashlib.sha256((p/'libbox.aar').read_bytes()).hexdigest() != m['aar_sha256']:
    raise SystemExit('Engineering AAR checksum mismatch')
PY
    [[ -x "$FLUTTER_ROOT/bin/flutter" ]] || { echo "Set LXBOX_AWG_FLUTTER to the pinned Flutter SDK" >&2; exit 1; }
    export JAVA_HOME="${LXBOX_AWG_APK_JAVA_HOME:-/usr/lib64/jvm/java-21-openjdk}"
    export PATH="$JAVA_HOME/bin:$FLUTTER_ROOT/bin:$PATH"
    # Flutter may select Android Studio's JBR for its Gradle client. Pin the daemon too.
    export GRADLE_OPTS="${GRADLE_OPTS:-} -Dorg.gradle.java.home=$JAVA_HOME"
    export ANDROID_HOME="$ANDROID_SDK" ANDROID_SDK_ROOT="$ANDROID_SDK"
    export LXBOX_LIBBOX_AAR="$ARTIFACT_ROOT/libbox.aar" LXBOX_ABI_FILTER=arm64-v8a
    BASE_TAG="$(git -C "$REPO_ROOT" describe --tags --abbrev=0 --match 'v*' 2>/dev/null || true)"
    BASE_VERSION="${BASE_TAG#v}"
    BASE_VERSION="${BASE_VERSION:-0.0.0}"
    BUILD_NUMBER="$("$REPO_ROOT/scripts/version-code.sh" "$BASE_VERSION" arm64-v8a)"
    sha256sum "$REPO_ROOT/app/android/app/libs/libbox.aar" "$REPO_ROOT/app/android/libbox.version" \
        > "$ARTIFACT_ROOT/evidence/production-core-before.sha256"
    (
        cd "$REPO_ROOT/app"
        # Debug signing is explicit. Nothing is installed and pubspec is not rewritten.
        flutter build apk --debug --no-pub --target-platform android-arm64 \
            --build-name "$BASE_VERSION-dev.awg700" --build-number "$BUILD_NUMBER"
    ) > "$ARTIFACT_ROOT/evidence/apk-build.log" 2>&1
    cp "$REPO_ROOT/app/build/app/outputs/flutter-apk/app-debug.apk" "$ARTIFACT_ROOT/lxbox-awg700-arm64-debug.apk"
    BUILD_TOOLS="${LXBOX_AWG_BUILD_TOOLS:-$ANDROID_SDK/build-tools/36.1.0}"
    "$BUILD_TOOLS/apksigner" verify --print-certs "$ARTIFACT_ROOT/lxbox-awg700-arm64-debug.apk" \
        > "$ARTIFACT_ROOT/evidence/apk-signature.txt"
    "$BUILD_TOOLS/aapt" dump badging "$ARTIFACT_ROOT/lxbox-awg700-arm64-debug.apk" \
        > "$ARTIFACT_ROOT/evidence/apk-badging.txt"
    sha256sum -c "$ARTIFACT_ROOT/evidence/production-core-before.sha256" \
        > "$ARTIFACT_ROOT/evidence/production-core-unchanged.txt"
    python3 - "$REPO_ROOT" "$ARTIFACT_ROOT" <<'PY'
import hashlib, json, pathlib, re, subprocess, sys, zipfile
repo, output = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
apk = output / 'lxbox-awg700-arm64-debug.apk'
with zipfile.ZipFile(apk) as z:
    libraries = sorted(n for n in z.namelist() if n.startswith('lib/') and n.endswith('.so'))
    if not libraries or any(not n.startswith('lib/arm64-v8a/') for n in libraries):
        raise SystemExit('APK ABI boundary failed: expected arm64-v8a only')
badging = (output/'evidence/apk-badging.txt').read_text()
signature = (output/'evidence/apk-signature.txt').read_text()
package = re.search(r"package: name='([^']+)' versionCode='([^']+)' versionName='([^']+)'", badging)
if not package:
    raise SystemExit('Cannot read APK package/version evidence')
certificate = re.search(r'Signer #1 certificate SHA-256 digest: (\S+)', signature)
minimum_sdk = re.search(r"^sdkVersion:'(\d+)'", badging, re.M)
target_sdk = re.search(r"^targetSdkVersion:'(\d+)'", badging, re.M)
if not minimum_sdk or minimum_sdk.group(1) != '24':
    raise SystemExit('APK minimum SDK boundary failed: expected API 24')
manifest = {
    'task': 700, 'kind': 'dedicated-device engineering debug APK; not a release',
    'lxbox_base_revision': subprocess.check_output(['git', '-C', str(repo), 'rev-parse', 'HEAD'], text=True).strip(),
    'lxbox_has_uncommitted_changes': bool(subprocess.check_output(['git', '-C', str(repo), 'status', '--porcelain'], text=True)),
    'package': package.group(1), 'version_code': package.group(2), 'version_name': package.group(3),
    'min_sdk': int(minimum_sdk.group(1)), 'target_sdk': int(target_sdk.group(1)) if target_sdk else None,
    'signing_channel': 'local Android debug key',
    'certificate_sha256': certificate.group(1) if certificate else None,
    'apk_sha256': hashlib.sha256(apk.read_bytes()).hexdigest(),
    'aar_sha256': hashlib.sha256((output/'libbox.aar').read_bytes()).hexdigest(),
    'production_aar_sha256': hashlib.sha256((repo/'app/android/app/libs/libbox.aar').read_bytes()).hexdigest(),
    'production_pin': (repo/'app/android/libbox.version').read_text().strip(),
    'production_aar_replaced': False, 'production_pin_changed': False,
    'native_libraries': libraries, 'installed': False, 'device_acceptance': 'not executed',
}
(output/'APK-MANIFEST.json').write_text(json.dumps(manifest, indent=2)+'\n')
PY
fi
(
    cd "$ARTIFACT_ROOT"
    sha256sum libbox.aar AAR-MANIFEST.json classes.jar > SHA256SUMS
    if [[ -f lxbox-awg700-arm64-debug.apk ]]; then sha256sum lxbox-awg700-arm64-debug.apk APK-MANIFEST.json >> SHA256SUMS; fi
)
echo "Engineering $ACTION artifacts: $ARTIFACT_ROOT (not installed)"
