#!/usr/bin/env bash
# Applies Kyodai's Android build-template patches to a Godot android_source.zip
# and verifies each one landed. Single source of truth for template patches:
# CI (.github/workflows/export.yml) calls this before --export, and it can be
# run locally against ~/.local/share/godot/export_templates/<ver>/android_source.zip
# so a reinstalled android/build template (gitignored, generated) still carries
# the patches.
#
# Why the patches exist:
# 1. PiP off - Kyodai is used as a home app on handhelds, and AOSP strips PiP
#    support from home-typed activities (ActivityRecord.supportsPictureInPicture()
#    requires a standard/undefined activity type). Godot 4.7's Android template
#    enables PiP unconditionally (manifest flag + GodotApp.isPiPEnabled()->true),
#    so the engine's setup-time setPictureInPictureParams() throws
#    IllegalStateException and crash-loops the app on every cold start as home.
# 2. configChanges hardening - a config change while Kyodai is stopped (e.g.
#    handheld display-mode juggling around game launch) forces an activity
#    relaunch on resume. Handling every config class prevents the relaunch.
# 3. GodotApp recreate guard - rapid same-process activity recreation (observed
#    when returning to Kyodai-as-HOME from a game) can kill the Vulkan surface
#    mid-reattach, leaving a black screen with dead input. The guard restarts
#    the process cleanly instead. See godotapp_recreate_guard.patch.
# 4. Home-intent forwarding - GodotPlugin has no onNewIntent hook, so retained
#    sessions receive Home through the existing GodotApp activity. No subclass,
#    duplicate activity, or launcher-alias override is involved.
# 5. Foreground activity tracking - settings and external intents must launch
#    from the currently resumed Kyodai activity, not the first activity created
#    in the process, or returning can resume a stale task with a black surface.
#
# Idempotent: safe to re-run against an already-patched zip.
#
# Usage: apply_template_patches.sh <path-to-android_source.zip>

set -euo pipefail

TPL="${1:?usage: apply_template_patches.sh <path-to-android_source.zip>}"
PATCH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
cd "$WORK"

unzip -o -q "$TPL" src/main/AndroidManifest.xml src/main/java/com/godot/game/GodotApp.java

# 1. PiP off
sed -i 's/android:supportsPictureInPicture="true"/android:supportsPictureInPicture="false"/' \
  src/main/AndroidManifest.xml
sed -i '/isPiPEnabled/,/}/s/return true;/return false;/' \
  src/main/java/com/godot/game/GodotApp.java

# 2. configChanges hardening: handle every config class in-process
sed -i 's/android:configChanges="[^"]*"/android:configChanges="layoutDirection|locale|orientation|keyboardHidden|screenSize|smallestScreenSize|density|keyboard|navigation|screenLayout|uiMode|fontScale|mcc|mnc|touchscreen|colorMode|fontWeightAdjustment|grammaticalGender"/' \
  src/main/AndroidManifest.xml

# 3. GodotApp recreate guard (unified diff; base is the post-PiP-patch file)
if grep -q kyodai_recreate_guard src/main/java/com/godot/game/GodotApp.java; then
  echo "recreate guard already present, skipping patch"
else
  patch -p0 < "$PATCH_DIR/godotapp_recreate_guard.patch"
fi

# 4. Forward Home intents through the existing GodotApp activity.
if grep -q kyodai_home_forwarding src/main/java/com/godot/game/GodotApp.java; then
  echo "Home-intent forwarding already present, skipping patch"
else
  patch -p0 < "$PATCH_DIR/godotapp_home_forwarding.patch"
fi

# 5. Track the currently resumed Kyodai activity for external intents.
if grep -q kyodai_activity_tracking src/main/java/com/godot/game/GodotApp.java; then
  echo "Foreground activity tracking already present, skipping patch"
else
  patch -p0 < "$PATCH_DIR/godotapp_activity_tracking.patch"
fi

# Update the two entries in place (python3 zipfile: available on CI runners and
# dev machines alike; the zip(1) CLI is not).
python3 - "$TPL" <<'PYEOF'
import os, shutil, sys, tempfile, zipfile

tpl = sys.argv[1]
entries = ["src/main/AndroidManifest.xml", "src/main/java/com/godot/game/GodotApp.java"]
fd, tmp = tempfile.mkstemp(suffix=".zip", dir=os.path.dirname(tpl))
os.close(fd)
with zipfile.ZipFile(tpl, "r") as zin, zipfile.ZipFile(tmp, "w", zipfile.ZIP_DEFLATED) as zout:
    for item in zin.infolist():
        if item.filename in entries:
            with open(item.filename, "rb") as f:
                zout.writestr(item, f.read())
        else:
            zout.writestr(item, zin.read(item.filename))
shutil.move(tmp, tpl)
PYEOF

# Fail loudly if any patch didn't land (set -e: grep exit 1 fails the run)
unzip -p "$TPL" src/main/AndroidManifest.xml | grep -q 'supportsPictureInPicture="false"'
unzip -p "$TPL" src/main/AndroidManifest.xml | grep -q 'fontWeightAdjustment'
unzip -p "$TPL" src/main/java/com/godot/game/GodotApp.java | grep -q 'return false;'
unzip -p "$TPL" src/main/java/com/godot/game/GodotApp.java | grep -q 'kyodai_recreate_guard'
unzip -p "$TPL" src/main/java/com/godot/game/GodotApp.java | grep -q 'kyodai_home_forwarding'
unzip -p "$TPL" src/main/java/com/godot/game/GodotApp.java | grep -q 'kyodai_activity_tracking'
echo "Template patches applied and verified: $TPL"
