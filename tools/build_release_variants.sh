#!/usr/bin/env bash
# Builds the standard Kyodai.apk and the AYN Android 13 legacy artifact.
# The legacy artifact is post-processed to targetSdkVersion 22 because Godot's
# exporter enforces a higher minimum target. Both artifacts use the same source
# tree and signing key, but remain independent update channels.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
out_dir="$repo_root/dist/variants"
work_dir="$out_dir/.build"
mkdir -p "$out_dir" "$work_dir"

GODOT_BIN="${GODOT_BIN:-godot}"
if [[ -d /usr/lib/jvm/java-17-openjdk ]]; then
  export JAVA_HOME="${JAVA_HOME:-/usr/lib/jvm/java-17-openjdk}"
fi
APKTOOL_JAR="${APKTOOL_JAR:-apktool.jar}"
if [[ ! -f "$APKTOOL_JAR" ]]; then
  echo "Set APKTOOL_JAR to the apktool jar path (for example /opt/apktool.jar)." >&2
  exit 1
fi

APKSIGNER="${APKSIGNER:-$HOME/Android/Sdk/build-tools/35.0.0/apksigner}"
if [[ ! -x "$APKSIGNER" ]]; then
  echo "Set APKSIGNER to the apksigner executable path." >&2
  exit 1
fi

KS="${KS:-$HOME/.android/kyodai-release.keystore}"
KS_PASS="${KS_PASS:-android}"

preset="$repo_root/export_presets.cfg"
preset_backup="$work_dir/export_presets.original.cfg"
cp "$preset" "$preset_backup"
restore_preset() {
  if [[ -f "$preset_backup" ]]; then
    cp "$preset_backup" "$preset"
  fi
}
trap restore_preset EXIT

# Standard artifact: current target and existing update channel.
(cd "$repo_root/android" && ./build_plugin.sh)
# Install the patched build template on clean CI runners as part of the first
# export; subsequent exports reuse android/build.
(cd "$repo_root" && "$GODOT_BIN" --headless --path . --install-android-build-template \
  --export-debug "Android" "$out_dir/Kyodai.apk")

# Legacy base artifact: export with the lowest target Godot accepts, then patch
# only the manifest's target SDK. Package identity and all other content stay
# identical to the standard channel.
python3 - "$preset" <<'PY'
import sys
path = sys.argv[1]
text = open(path).read()
text = text.replace('gradle_build/target_sdk=""', 'gradle_build/target_sdk=24')
text = text.replace('gradle_build/min_sdk=""', 'gradle_build/min_sdk=24')
open(path, 'w').write(text)
PY

legacy_base="$work_dir/legacy-base.apk"
(cd "$repo_root" && "$GODOT_BIN" --headless --path . --export-debug "Android" "$legacy_base")
restore_preset

decoded="$work_dir/decoded"
rm -rf "$decoded"
java -jar "$APKTOOL_JAR" d -f -o "$decoded" "$legacy_base"
python3 - "$decoded" <<'PY'
import pathlib
import re
import sys

root = pathlib.Path(sys.argv[1])
path = root / "AndroidManifest.xml"
text = path.read_text()
entry = '    <uses-sdk android:minSdkVersion="24" android:targetSdkVersion="22" />'
if '<uses-sdk ' in text:
    start = text.index('    <uses-sdk ')
    end = text.index('/>', start) + 2
    text = text[:start] + entry + text[end:]
else:
    marker = '    <supports-screens '
    text = text.replace(marker, entry + '\n' + marker, 1)
path.write_text(text)

# Apktool 3 also passes sdkInfo to aapt2. Keeping these values aligned with the
# manifest is required; otherwise the final APK retains the standard channel's
# SDK levels and resource validation sees conflicting metadata.
metadata = root / "apktool.yml"
text = metadata.read_text()
text = re.sub(r'minSdkVersion: \d+', 'minSdkVersion: 24', text)
text = re.sub(r'targetSdkVersion: \d+', 'targetSdkVersion: 22', text)
metadata.write_text(text)

# Adaptive icons require API 26. Target-22 resource linking rejects them, so
# preserve the same foreground/background artwork in an API-1 layer-list. Keep
# resource names/public IDs and the standard channel untouched.
layer_list = '''<?xml version="1.0" encoding="utf-8"?>
<layer-list xmlns:android="http://schemas.android.com/apk/res/android">
    <item android:drawable="@mipmap/icon_background" />
    <item android:drawable="@mipmap/icon_foreground" />
</layer-list>
'''
for name in ("icon.xml", "themed_icon.xml"):
    icon = root / "res" / "mipmap-anydpi" / name
    if icon.is_file() and "<adaptive-icon" in icon.read_text():
        icon.write_text(layer_list)
PY

unsigned="$work_dir/legacy-unsigned.apk"
java -jar "$APKTOOL_JAR" b -o "$unsigned" "$decoded"
"$APKSIGNER" sign --ks "$KS" --ks-pass "pass:$KS_PASS" --out "$out_dir/Kyodai-legacy.apk" "$unsigned"

rm -rf "$work_dir"
echo "Built: $out_dir/Kyodai.apk"
echo "Built: $out_dir/Kyodai-legacy.apk"
