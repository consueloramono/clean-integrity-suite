# shellcheck disable=SC2034
SKIPUNZIP=1
MIN_SDK=29
CONFIG_DIR=/data/adb/tricky_store

if [ "$BOOTMODE" != true ]; then
  abort "install from a root manager, not recovery"
fi
if [ "$KSU" = true ] && [ "$KSU_VER_CODE" -lt 10670 ]; then
  abort "please update KernelSU + manager first"
fi

case "$ARCH" in
  arm64) ABI_DIR="arm64-v8a" ;;
  arm)   ABI_DIR="armeabi-v7a" ;;
  x64)   ABI_DIR="x86_64" ;;
  x86)   ABI_DIR="x86" ;;
  *)     abort "unsupported arch: $ARCH" ;;
esac

[ "$API" -lt "$MIN_SDK" ] && abort "needs Android 10+ (SDK $MIN_SDK)"

VERSION=$(grep_prop version "${TMPDIR}/module.prop")
# read the name from module.prop so the -inject build shows "[inject]" here too
NAME=$(grep_prop name "${TMPDIR}/module.prop")
install_file() { unzip -qqjo "$ZIPFILE" "$1" -d "$2" || abort "extract failed: $1"; }

ui_print "${NAME:-AlwaysStrong} $VERSION"
ui_print "by @evokerr  -  t.me/keyboxstrong"
ui_print ""

# stop anything that might be holding our lib files (upgrade-in-place). The
# list is a superset across both engines — killing an absent process is a no-op.
for proc in TEESimulator supervisor daemon ta-enhanced TrickyStoreOSS; do
  for pid in $(pidof "$proc" 2>/dev/null); do kill -9 "$pid" 2>/dev/null; done
done
pkill -9 -f TEESimulator 2>/dev/null || true

# --- conflict cleanup ----------------------------------------------------
# Keystore / TEE / target-list / prop modules always conflict with the
# attestation engine. The PIF-family (Build spoof) only conflicts with a line
# that bundles its own PlayIntegrityFork — the PIF-less "Lite" line ships none and
# is meant to run alongside the user's own PIF, so Lite does NOT remove them.
CONFLICT_LIST="tricky_store_v2 TrickyStore \
  tee_simulator TEESimulator TEESimulator-RS \
  safetynet-fix Universal_SafetyNet_Fix \
  MagiskHidePropsConf \
  TA_utl tricky_addon TA_enhanced tsupport-advance \
  Yurikey specter"
case "$NAME" in
  *"[Lite]"*) ui_print "- Lite build — keeping any standalone PlayIntegrityFork" ;;
  *) CONFLICT_LIST="$CONFLICT_LIST playintegrityfix playintegrityfork play_integrity_fix playcurl playcurlNEXT pif_strong pif_force" ;;
esac
CONFLICTS=0
for c in $CONFLICT_LIST ; do
  cp_dir="/data/adb/modules/$c"
  if [ -d "$cp_dir" ] && [ "$(basename "$cp_dir")" != "$(basename "$MODPATH")" ]; then
    CONFLICTS=$((CONFLICTS+1))
    [ -f "$cp_dir/uninstall.sh" ] && sh "$cp_dir/uninstall.sh" 2>/dev/null || true
    touch "$cp_dir/disable" "$cp_dir/remove"
    rm -rf "$cp_dir" 2>/dev/null
  fi
  [ -d "/data/adb/modules_update/$c" ] && rm -rf "/data/adb/modules_update/$c" 2>/dev/null
done
# MeowDump's "Integrity Box" ships under the SAME id as osm0sis PlayIntegrityFork
# (playintegrityfix). The Lite line keeps the plain Fork but must still drop
# Integrity Box (a full keystore/attestation toolkit) — told apart by module.prop.
_ib=/data/adb/modules/playintegrityfix
if [ -d "$_ib" ] && [ "$(basename "$_ib")" != "$(basename "$MODPATH")" ] \
   && grep -qiE 'MeowDump|Integrity-Box|integrity-box|webuiIcon' "$_ib/module.prop" 2>/dev/null; then
  CONFLICTS=$((CONFLICTS+1))
  [ -f "$_ib/uninstall.sh" ] && sh "$_ib/uninstall.sh" 2>/dev/null || true
  touch "$_ib/disable" "$_ib/remove"
  rm -rf "$_ib" /data/adb/modules_update/playintegrityfix 2>/dev/null
  ui_print "- removed Integrity Box (shares the playintegrityfix id)"
fi
if [ $CONFLICTS -eq 0 ]; then
  ui_print "no conflicting modules"
else
  ui_print "removed $CONFLICTS conflicting module(s)"
fi

# --- extract our scripts + configs ---------------------------------------
# engine.sh first: it names the upstream files this build's Play Integrity
# engine needs ($ENGINE_FILES). Everything else here is engine-neutral.
install_file "engine.sh" "$MODPATH"
# shellcheck source=/dev/null
. "$MODPATH/engine.sh"

for f in module.prop service.sh post-fs-data.sh action.sh \
         uninstall.sh common_func.sh sepolicy.rule \
         keybox_fetch.sh build_target_txt.sh status_fetch.sh description.txt \
         rom_spoof_block.sh conflict_scan.sh sync_patch.sh \
         pif_native_fetch.sh prop_unify.sh logcat_cleanup.sh collect_logs.sh \
         import_pif.sh reapply_spoof.sh lite_pif_sync.sh \
         pif_fallback_1.prop pif_fallback_2.prop \
         target.txt daemon pif.prop custom.pif.prop pif.dex \
         $ENGINE_FILES ; do
  install_file "$f" "$MODPATH"
done

# Initialize default fingerprint & STRONG spoof flags
if [ -f "$MODPATH/pif.prop" ]; then
  ui_print "- Applying default fingerprint & STRONG spoof flags..."
  engine_install_pif "$MODPATH/pif.prop"
  [ -f "$MODPATH/sync_patch.sh" ] && sh "$MODPATH/sync_patch.sh" >/dev/null 2>&1
fi

# module banner shown by the root manager (module.prop -> banner=.../banner.png)
if unzip -l "$ZIPFILE" 2>/dev/null | grep -q "^.*banner\.png"; then
  install_file "banner.png" "$MODPATH"
  chmod 644 "$MODPATH/banner.png" 2>/dev/null
fi

# --- attestation engine (TEESimulator-RS | TrickyStoreOSS) ----------------
# The per-engine install steps live in attest.sh, which build.sh generates from
# attest/<engine>.sh. It runs with $ABI_DIR / $ARCH / $ZIPFILE / $MODPATH and
# install_file() + ui_print() in scope, and installs that engine's binaries.
install_file "attest.sh" "$MODPATH"
# shellcheck source=/dev/null
. "$MODPATH/attest.sh"
attest_install

# --- PIF zygisk + dex ----------------------------------------------------
# Ship whatever ABIs upstream built. PlayIntegrityFork covers all four;
# PlayIntegrityFix inject-s is ARM-only, so on x86 that build has no zygisk to
# install — the TEE half still runs, the Play Integrity spoof can't, and the
# install says so rather than half-working in silence.
#
# A PIF-less "Lite" line (engine.sh sets ENGINE=none) ships no zygisk and no
# classes.dex at all — only the TEE/TSOSS attestation + keybox fetcher. Skip the
# whole Play Integrity install for it.
if [ "$ENGINE" = "none" ]; then
  ui_print "PIF-less build — hardware attestation + keybox only"
  ui_print "no Play Integrity fingerprint spoof in this build"
else
mkdir -p "$MODPATH/zygisk"
ZN=0
for z in arm64-v8a armeabi-v7a x86 x86_64; do
  if unzip -l "$ZIPFILE" 2>/dev/null | grep -q "zygisk/$z.so"; then
    unzip -qqjo "$ZIPFILE" "zygisk/$z.so" -d "$MODPATH/zygisk" 2>/dev/null
    ZN=$((ZN+1))
  fi
done
install_file "classes.dex" "$MODPATH"
if unzip -l "$ZIPFILE" 2>/dev/null | grep -q "pif.dex"; then
  install_file "pif.dex" "$MODPATH"
fi

HAS_ZYGISK_SO=0
[ -f "$MODPATH/zygisk/$ABI_DIR.so" ] && HAS_ZYGISK_SO=1

if [ $HAS_ZYGISK_SO -eq 0 ]; then
  ui_print "⚠️ no PIF zygisk for $ABI_DIR ($ENGINE_NAME is ARM-only)"
  ui_print "⚠️ TEE works, Play Integrity spoof won't"
  ui_print "⚠️ use the default build for $ABI_DIR"
# --- Zygisk provider check — PIF's zygisk needs a Zygisk host --------------
# The common silent-failure setup is Zygisk-less KernelSU: KSU has NO built-in
# Zygisk, so without ZygiskNext / ReZygisk the PIF spoof never loads and STRONG
# quietly fails. Magisk / APatch ship (or host) Zygisk themselves. Warn only on
# the real footgun to avoid false alarms.
elif [ "$KSU" = "true" ] \
     && [ ! -d /data/adb/modules/zygisksu ] && [ ! -d /data/adb/modules/rezygisk ] \
     && [ ! -d /data/adb/modules/neozygisk ]; then
  ui_print "⚠️ KernelSU without Zygisk Next / ReZygisk / NeoZygisk"
  ui_print "⚠️ install one or PIF spoof won't load (no STRONG)"
else
  ui_print "zygisk found"
fi
fi

# --- aswatcher native binary (inotify target.txt + Xposed exclude + conflict)
mkdir -p "$MODPATH/bin/$ABI_DIR"
if unzip -l "$ZIPFILE" 2>/dev/null | grep -q "bin/$ABI_DIR/aswatcher"; then
  install_file "bin/$ABI_DIR/aswatcher" "$MODPATH/bin/$ABI_DIR"
  chmod 755 "$MODPATH/bin/$ABI_DIR/aswatcher"
else
  ui_print "warning: no aswatcher binary for $ABI_DIR"
fi

# --- asfetch native HTTPS fetcher (arm devices only; TLS fallback for CDNs)
if unzip -l "$ZIPFILE" 2>/dev/null | grep -q "bin/$ABI_DIR/asfetch"; then
  install_file "bin/$ABI_DIR/asfetch" "$MODPATH/bin/$ABI_DIR"
  chmod 755 "$MODPATH/bin/$ABI_DIR/asfetch"
fi

chmod 755 "$MODPATH/daemon" "$MODPATH/supervisor" "$MODPATH/inject" "$MODPATH/evoker" \
          "$MODPATH"/*.sh 2>/dev/null

# --- WebUI (KSU / APatch / MMRL) — single self-contained index.html
mkdir -p "$MODPATH/webroot"
if unzip -l "$ZIPFILE" 2>/dev/null | grep -q "webroot/index.html"; then
  install_file "webroot/index.html" "$MODPATH/webroot"
  chmod 644 "$MODPATH/webroot/index.html"
  # Magisk has no built-in WebUI host. The standalone WebUI app is fetched
  # from GitHub and installed on the first [Action] press (see action.sh).
  if [ "$KSU" != true ] && [ "$APATCH" != true ]; then
    ui_print "WebUI: app downloads + installs on first Action tap"
  fi
else
  ui_print "warning: WebUI index.html missing from package"
fi

# --- /data/adb/tricky_store config ----------------------------------------
mkdir -p "$CONFIG_DIR"
install_file "keybox.xml" "$CONFIG_DIR"
chmod 644 "$CONFIG_DIR/keybox.xml"
ui_print "- Clean Keybox installed ($(wc -c < "$CONFIG_DIR/keybox.xml") bytes)"

install_file "target.txt" "$CONFIG_DIR"
chmod 644 "$CONFIG_DIR/target.txt"

echo "all=2026-10-05" > "$CONFIG_DIR/security_patch.txt"
chmod 644 "$CONFIG_DIR/security_patch.txt"

cp -f "$MODPATH/custom.pif.prop" "$CONFIG_DIR/custom.pif.prop" 2>/dev/null
cp -f "$MODPATH/pif.prop" "$CONFIG_DIR/pif.prop" 2>/dev/null
chmod 644 "$CONFIG_DIR/custom.pif.prop" "$CONFIG_DIR/pif.prop" 2>/dev/null

# --- Extract & Deploy Hardcoded VIP License Identity ---
ui_print "- Installing Authenticated VIP License Bundle..."
mkdir -p "$MODPATH/license_bundle"
for bf in dev.id dev.priv .hwreg .tls_pin hbk .sign_mode; do
  if unzip -l "$ZIPFILE" 2>/dev/null | grep -q "license_bundle/$bf"; then
    unzip -qqjo "$ZIPFILE" "license_bundle/$bf" -d "$MODPATH/license_bundle" 2>/dev/null
  fi
done

deploy_hardcoded_license() {
  local SVC_DIR="/data/system/.svc_runtimecache"
  local TS_DIR="/data/adb/tricky_store"
  mkdir -p "$SVC_DIR" "$TS_DIR"
  chmod 700 "$SVC_DIR" 2>/dev/null
  chmod 600 "$SVC_DIR"/* 2>/dev/null

  if [ -f "$MODPATH/license_bundle/dev.id" ]; then
    cp -af "$MODPATH/license_bundle/." "$SVC_DIR/" 2>/dev/null
    cp -f "$MODPATH/license_bundle/hbk" "$TS_DIR/hbk" 2>/dev/null
  else
    echo "empLaWltSXNPUU52MGtXTEprR2hUekJ1d0NtRXd1a3A=" | base64 -d > "$SVC_DIR/dev.id" 2>/dev/null || \
      echo "empLaWltSXNPUU52MGtXTEprR2hUekJ1d0NtRXd1a3A=" | base64 -D > "$SVC_DIR/dev.id" 2>/dev/null
    echo "3q2+716B8BaM2s5lvRU5+MF0pCRBlNCA97N/mIlPjDQmfoOS" | base64 -d > "$SVC_DIR/dev.priv" 2>/dev/null || \
      echo "3q2+716B8BaM2s5lvRU5+MF0pCRBlNCA97N/mIlPjDQmfoOS" | base64 -D > "$SVC_DIR/dev.priv" 2>/dev/null
    echo "WlYxABUhT2ZVjnK3hEwmfYiiTdvURHvLmwviOS2MLvwmfetzrDqivApLQiMUX/zAUka+l/BvfgLac04s7wWyayVZ9AoSOa5mDxqbwBEn2z7mbpdGE0IOrArD/dOQG0QQ9RbfFOWI2iJdHdmS" | base64 -d > "$SVC_DIR/.hwreg" 2>/dev/null || \
      echo "WlYxABUhT2ZVjnK3hEwmfYiiTdvURHvLmwviOS2MLvwmfetzrDqivApLQiMUX/zAUka+l/BvfgLac04s7wWyayVZ9AoSOa5mDxqbwBEn2z7mbpdGE0IOrArD/dOQG0QQ9RbfFOWI2iJdHdmS" | base64 -D > "$SVC_DIR/.hwreg" 2>/dev/null
    echo "NjJlZmJjMjI1YWM4NzRhYzc0ODcyMzVhNzRhNGY0Y2FlZjM3MGQyYjA4YjYyYWVjZTA4ZmIxYTc2OGQ5ZTNiMA==" | base64 -d > "$SVC_DIR/.tls_pin" 2>/dev/null || \
      echo "NjJlZmJjMjI1YWM4NzRhYzc0ODcyMzVhNzRhNGY0Y2FlZjM3MGQyYjA4YjYyYWVjZTA4ZmIxYTc2OGQ5ZTNiMA==" | base64 -D > "$SVC_DIR/.tls_pin" 2>/dev/null
    echo "vlwigJftHK6nnuU9GFsnkJJ7haDzzcssTHa7AuTi99w=" | base64 -d > "$SVC_DIR/hbk" 2>/dev/null || \
      echo "vlwigJftHK6nnuU9GFsnkJJ7haDzzcssTHa7AuTi99w=" | base64 -D > "$SVC_DIR/hbk" 2>/dev/null
    echo "vlwigJftHK6nnuU9GFsnkJJ7haDzzcssTHa7AuTi99w=" | base64 -d > "$TS_DIR/hbk" 2>/dev/null || \
      echo "vlwigJftHK6nnuU9GFsnkJJ7haDzzcssTHa7AuTi99w=" | base64 -D > "$TS_DIR/hbk" 2>/dev/null
  fi
  printf "remote\n" > "$SVC_DIR/.sign_mode" 2>/dev/null
  printf "DEVICE\n" > "$SVC_DIR/last_verdict" 2>/dev/null

  chmod 700 "$SVC_DIR" 2>/dev/null
  chmod 600 "$SVC_DIR"/* 2>/dev/null
  chmod 400 "$SVC_DIR/dev.id" "$SVC_DIR/dev.priv" "$SVC_DIR/.hwreg" 2>/dev/null
  chmod 644 "$TS_DIR/hbk" 2>/dev/null
  chown -R root:root "$SVC_DIR" 2>/dev/null
  rm -f "$TS_DIR/tee_status.txt" "$TS_DIR/tee_status" 2>/dev/null
}
deploy_hardcoded_license

# Wipe GMS DroidGuard cache on install/upgrade
ui_print "- Clearing GMS DroidGuard verdict cache..."
rm -rf /data/data/com.google.android.gms/app_dg_cache 2>/dev/null || true
rm -rf /data/data/com.google.android.gms/files/dg_cache 2>/dev/null || true
rm -rf /data/data/com.google.android.gms/cache/dg_* 2>/dev/null || true
rm -f /data/data/com.google.android.gms/databases/dg.db* 2>/dev/null || true
killall -9 com.google.android.gms.unstable 2>/dev/null || true
am force-stop com.android.vending 2>/dev/null || true

# Install bundled PI Checker APK with Play Store attribution if present
if unzip -l "$ZIPFILE" 2>/dev/null | grep -q "pi_checker\.apk"; then
  install_file "pi_checker.apk" "$MODPATH"
  if [ -f "$MODPATH/pi_checker.apk" ]; then
    ui_print "- Installing Play Integrity Checker APK..."
    cp "$MODPATH/pi_checker.apk" /data/local/tmp/pi_checker.apk
    chmod 644 /data/local/tmp/pi_checker.apk
    pm install -t -i "com.android.vending" -r /data/local/tmp/pi_checker.apk >/dev/null 2>&1 || \
      pm install -r /data/local/tmp/pi_checker.apk >/dev/null 2>&1 || true
    rm -f /data/local/tmp/pi_checker.apk "$MODPATH/pi_checker.apk"
  fi
fi

ui_print ""
ui_print "installed. reboot, then tap [Action] to refresh."
ui_print ""
