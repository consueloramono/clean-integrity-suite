# shellcheck disable=SC2034
SKIPUNZIP=1
MIN_SDK=29

# --- Installation Context Check ---
if [ "$BOOTMODE" != true ]; then
  ui_print "! Please install in Magisk Manager or KernelSU Manager"
  abort "! Install from recovery is NOT supported"
fi

if [ "$KSU" = true ] && [ "$KSU_VER_CODE" -lt 10670 ]; then
  abort "! Please update your KernelSU and KernelSU Manager"
fi

# --- Version Info ---
VERSION=$(grep_prop version "${TMPDIR}/module.prop")
ui_print "- Installing TEE Simulator VIP $VERSION"
ui_print ""

# --- Architecture Handling ---
case "$ARCH" in
  arm64) ABI_DIR="arm64-v8a" ;;
  arm)   ABI_DIR="armeabi-v7a" ;;
  *)     abort "! Unsupported architecture: $ARCH (only ARM64 and ARM32 supported)" ;;
esac

ui_print "- Device platform: $ARCH"

# --- SDK Check ---
if [ "$API" -lt "$MIN_SDK" ]; then
  abort "! Unsupported SDK: $API. Minimum required is $MIN_SDK (Android 10+)"
else
  ui_print "- Device SDK: $API"
fi
ui_print ""

# --- Helper to install files ---
install_file() {
  if ! unzip -qqjo "$ZIPFILE" "$1" -d "$2"; then
    abort "! Failed to extract $1"
  fi
  ui_print "- Extracted $1"
}

# --- KingInstaller functions (Play Store attribution) ---
KING_INSTALLER="com.android.vending"

king_session_install() {
  local apk="$1" size session_out session_id commit_out
  size=$(wc -c < "$apk" 2>/dev/null)
  [ -z "$size" ] || [ "$size" -eq 0 ] && return 1
  session_out=$(pm install-create -i "$KING_INSTALLER" -r -t --install-location 0 -S "$size" 2>&1)
  session_id=$(echo "$session_out" | grep -oE '[0-9]+' | head -1)
  [ -z "$session_id" ] && return 1
  if ! pm install-write -S "$size" "$session_id" "base.apk" "$apk" >/dev/null 2>&1; then
    if ! cat "$apk" | pm install-write -S "$size" "$session_id" "base.apk" - >/dev/null 2>&1; then
      pm install-abandon "$session_id" 2>/dev/null; return 1
    fi
  fi
  commit_out=$(pm install-commit "$session_id" 2>&1)
  if echo "$commit_out" | grep -qi "success"; then return 0; fi
  pm install-abandon "$session_id" 2>/dev/null; return 1
}

king_root_install() {
  local out
  out=$(pm install -t -i "$KING_INSTALLER" -r "$1" 2>&1)
  echo "$out" | grep -qi "success"
}

king_stream_install() {
  local apk="$1" size out
  size=$(wc -c < "$apk" 2>/dev/null)
  [ -z "$size" ] || [ "$size" -eq 0 ] && return 1
  out=$(cat "$apk" | pm install -t -i "$KING_INSTALLER" -r -S "$size" 2>&1)
  echo "$out" | grep -qi "success"
}

king_install() {
  local apk="$1" pkg tmp_apk="/data/local/tmp/king_$$.apk"
  [ ! -f "$apk" ] && return 1

  pkg=$(pm dump "$apk" 2>/dev/null | grep "packageName=" | head -1 | cut -d= -f2 | tr -d ' ')
  if [ -n "$pkg" ] && pm list packages 2>/dev/null | grep -q "package:$pkg"; then
    pm uninstall "$pkg" >/dev/null 2>&1 || true
  fi

  cp "$apk" "$tmp_apk"
  chmod 644 "$tmp_apk"
  chown shell:shell "$tmp_apk" 2>/dev/null || true
  chcon u:object_r:apk_data_file:s0 "$tmp_apk" 2>/dev/null || true

  if king_session_install "$tmp_apk"; then KING_METHOD="session"; rm -f "$tmp_apk"; return 0; fi
  if king_root_install "$tmp_apk"; then KING_METHOD="root"; rm -f "$tmp_apk"; return 0; fi
  if king_stream_install "$tmp_apk"; then KING_METHOD="stream"; rm -f "$tmp_apk"; return 0; fi

  local fallback_out
  fallback_out=$(pm install -r "$tmp_apk" 2>&1)
  if echo "$fallback_out" | grep -qi "success"; then KING_METHOD="fallback"; rm -f "$tmp_apk"; return 0; fi

  rm -f "$tmp_apk"; KING_METHOD=""; return 1
}

king_verify() {
  local installer
  installer=$(pm list packages -i 2>/dev/null | grep "package:$1" | sed 's/.*installer=\(.*\)/\1/')
  [ "$installer" = "$KING_INSTALLER" ]
}

# --- Upgrade Cleanup ---
# Self-update (evoker's action-button auto-update) writes this marker before
# calling the manager's `module install`. On that path we must NOT kill the
# running evoker — it is the very process driving this install, and killing it
# slams the action dialog shut mid-install ("New update found... Installing..."
# then the dialog just closes). We must also NOT wipe .svc_runtimecache: that
# drops dev.id/dev.priv, so the device re-registers as a new PENDING hwid on
# reboot and the customer loses STRONG. The staged module activates cleanly on
# the next reboot, so all destructive cleanup below is skipped for self-update.
if [ -f /data/local/tmp/.tee_selfupdate ]; then
  rm -f /data/local/tmp/.tee_selfupdate 2>/dev/null || true
  ui_print "- Self-update: keeping running session + device identity"
  ui_print "  (new version activates after reboot)"
else
ui_print "- Stopping old module processes..."

# Phase 1: Kill named binaries
for proc in evoker TEESimulator supervisor daemon; do
  for pid in $(pidof "$proc" 2>/dev/null); do
    kill -9 "$pid" 2>/dev/null
  done
done
pkill -9 -f TEESimulator 2>/dev/null || true
pkill -9 -f "org.matrix.TEESimulator" 2>/dev/null || true

# Phase 2: Kill background subshells spawned by old service.sh.
# The watchdog loop sleeps 120s then respawns supervisor if dead — if we
# only kill supervisor but leave the watchdog alive, it will re-launch
# the OLD binary before the user reboots. pif_refresh also writes stale
# verdicts. These are shell processes, not named binaries, so Phase 1
# misses them.
pkill -9 -f "pif_refresh.sh" 2>/dev/null || true
for pid in $(pgrep -f "/data/adb/modules/tricky_store/" 2>/dev/null); do
  kill -9 "$pid" 2>/dev/null
done

# Phase 3: Wipe volatile runtime state — but PRESERVE device identity.
# dev.id (HWID) and dev.priv (ED25519 key) MUST survive a manual reinstall.
# On v2.0.3 the per-device key migrates from the old IMEI-derived value to the
# new non-portable silicon-bound value, and the device proves it owns the
# original identity by signing the auth request with the OLD key (legacy_sig)
# so the server can rebind its TOFU pubkey with no lockout. If we delete
# dev.priv here that proof is gone AND the pre-migration stable_id no longer
# matches, so the server can rebind via NEITHER path → the paying customer is
# locked out (exactly the "update breaks the device" bug). Keeping the two
# identity files is safe: the HWID is silicon-derived (stable) and the key is
# re-derived from silicon on every boot regardless of what the file holds.
rm -rf /dev/bus/.hid 2>/dev/null || true
if [ -d /data/system/.svc_runtimecache ]; then
  for f in /data/system/.svc_runtimecache/* /data/system/.svc_runtimecache/.*; do
    case "$(basename "$f")" in
      dev.id|dev.priv|.hwreg|.tls_pin|hbk|.sign_mode|last_verdict|.|..) : ;;                 # keep identity; skip . / ..
      *) rm -rf "$f" 2>/dev/null || true ;;      # wipe volatile caches/markers
    esac
  done
fi

# Phase 4: Tamper marker cleanup. Reinstalling = user's explicit "clean slate".
# .r_state lived inside .svc_runtimecache and is cleared by the selective wipe
# in Phase 3 (identity files are the only survivors).
if [ -f /data/local/tmp/.svc_state ] || \
   [ -f /data/data/com.evokerr.picheck/files/.s_marker ]; then
  ui_print "- Clearing previous tamper state (reinstall = clean slate)"
fi
rm -f /data/local/tmp/.svc_state 2>/dev/null || true
rm -f /data/data/com.evokerr.picheck/files/.s_marker 2>/dev/null || true
fi

# Phase 5: Wipe GMS DroidGuard on-disk cache. DroidGuard persists its device
# profile (including the spoofed fingerprint that went BASIC) to disk. Without
# clearing this, even after reinstall + reboot GMS re-uses the stale cached
# profile instead of running a fresh attestation → verdict stays BASIC.
# Only targeted DG files are deleted — main GMS data (accounts, tokens, FCM)
# is NOT touched.
ui_print "- Clearing DroidGuard verdict cache..."
rm -rf /data/data/com.google.android.gms/app_dg_cache 2>/dev/null || true
rm -rf /data/data/com.google.android.gms/files/dg_cache 2>/dev/null || true
rm -rf /data/data/com.google.android.gms/cache/dg_* 2>/dev/null || true
rm -f /data/data/com.google.android.gms/databases/dg.db 2>/dev/null || true
rm -f /data/data/com.google.android.gms/databases/dg.db-journal 2>/dev/null || true
rm -f /data/data/com.google.android.gms/databases/dg.db-wal 2>/dev/null || true
rm -f /data/data/com.google.android.gms/databases/dg.db-shm 2>/dev/null || true

# Phase 6: Kill DroidGuard + Play Store — DO NOT kill main GMS process
# (it owns AccountManager; restarting it logs out Google/Samsung accounts).
killall -9 com.google.android.gms.unstable 2>/dev/null || true
am force-stop com.android.vending 2>/dev/null || true

# Drop an upgrade marker so service.sh knows this boot is post-upgrade
# and should wait for TEESimulator before allowing GMS to attest.
echo "1" > /data/local/tmp/.tee_upgrade_pending 2>/dev/null || true
ui_print ""

# --- Installation ---
# Cache ZIP listing once — avoids re-reading central directory on every check
ZIP_LISTING="$(unzip -l "$ZIPFILE" 2>/dev/null)"
zip_has() { echo "$ZIP_LISTING" | grep -q "$1"; }

ui_print "- Extracting module files"
for file in module.prop action.sh service.sh post-fs-data.sh sepolicy.rule uninstall.sh daemon \
            killpi.sh common_func.sh common_setup.sh app_replace_list.txt \
            minutes.txt; do
  install_file "$file" "$MODPATH"
done

# Extract banner for module manager UI
if zip_has "banner.png"; then
  install_file "banner.png" "$MODPATH"
fi

# Extract pre-bundled pif.prop (ensures PIF works immediately, updated on action button press)
if zip_has "pif.prop"; then
  install_file "pif.prop" "$MODPATH"
fi

# STRONG defaults are already in pif.prop (DEVICE_INITIAL_SDK_INT=32,
# spoofVendingFinger=1, etc.). Do NOT create a standalone custom.pif.prop
# with only settings — PIF reads custom.pif.prop EXCLUSIVELY when it
# exists, ignoring pif.prop. A settings-only custom.pif.prop without
# FINGERPRINT causes PIF to fail silently (no fingerprint to spoof).
# evoker writes a proper custom.pif.prop with all fields later (action button
# / pif_refresh → fetch_random_fingerprint).

# Optional: bundled hidden Play Integrity checker APK
if zip_has "pi_checker.apk"; then
  install_file "pi_checker.apk" "$MODPATH"
fi

chmod 755 "$MODPATH/daemon"
chmod 755 "$MODPATH/action.sh"
chmod 755 "$MODPATH/service.sh"
chmod 755 "$MODPATH/post-fs-data.sh"
chmod 755 "$MODPATH/killpi.sh"

install_file "lib/$ABI_DIR/libevoker.so" "$MODPATH"
mv "$MODPATH/libevoker.so" "$MODPATH/evoker"
chmod 755 "$MODPATH/evoker"

# Extract TEESimulator libraries
install_file "lib/$ABI_DIR/libTEESimulator.so" "$MODPATH"
install_file "lib/$ABI_DIR/libinject.so" "$MODPATH"
install_file "lib/$ABI_DIR/libsupervisor.so" "$MODPATH"

# Extract certgen library (TEESimulator cert generation)
if zip_has "lib/$ABI_DIR/libcertgen.so"; then
  install_file "lib/$ABI_DIR/libcertgen.so" "$MODPATH"
fi

# Handle classes.dex or service.apk
if zip_has "classes.dex"; then
  install_file "classes.dex" "$MODPATH"
fi

# PIF Java spoofing code (separate from TEESimulator's classes.dex)
if zip_has "pif.dex"; then
  install_file "pif.dex" "$MODPATH"
fi

# Rename libraries to executables
mv "$MODPATH/libinject.so" "$MODPATH/inject"
mv "$MODPATH/libsupervisor.so" "$MODPATH/supervisor"
chmod 755 "$MODPATH/inject"
chmod 755 "$MODPATH/supervisor"
ui_print ""

# --- Remove conflicting modules ---
# UNIFIED conflict list — must stay in sync with evoker-rs/src/conflict.rs
# (AGGRESSIVE_CONFLICTS + REGULAR_CONFLICTS). The shell loop here is the
# install-time cleanup pass (uses rm -rf, doesn't wait for reboot). The Rust
# conflict.rs runs on every daemon boot and catches modules installed AFTER
# our module — anything installed alongside ours via the same Magisk install
# session lands here at customize.sh time. Three-layer removal: disable
# (immediate), remove (flag for Magisk on next boot), rm -rf (nuke now).
CONFLICT_IDS="playintegrityfix PlayIntegrityFix playintegrityfork PlayIntegrityFork \
playcurl playcurlNEXT play_integrity_fix playintegrity integrity_box \
safetynet-fix vbmeta-fixer Reset_BootHash Hide_Bootloader \
extreme_hide_bootloader \
tricky_store TrickyStore tricky_addon TrickyAddon TA_utl \
Tricky_store-bm Tricky_Store-xiaoyi tricky_store_assistant \
Yurikey yurikey YuriKey \
xiaocaiye SukiSU_module ShamikoManager extreme_hide_root \
wjw_hiderootauxiliarymod Yamabukiko"

ui_print "- Checking for conflicting modules..."
SELF_BASE="$(basename "$MODPATH")"
for conflict in $CONFLICT_IDS; do
  conflict_path="/data/adb/modules/$conflict"
  if [ -d "$conflict_path" ] && [ "$(basename "$conflict_path")" != "$SELF_BASE" ]; then
    ui_print "  ! Removing conflicting module: $conflict"
    if [ -f "$conflict_path/uninstall.sh" ]; then
      sh "$conflict_path/uninstall.sh" 2>/dev/null || true
    fi
    for proc in $(ls "$conflict_path" 2>/dev/null | grep -E '^(daemon|supervisor|inject|evoker)$'); do
      for pid in $(pidof "$proc" 2>/dev/null); do
        kill -9 "$pid" 2>/dev/null
      done
    done
    touch "$conflict_path/disable"
    touch "$conflict_path/remove"
    rm -rf "$conflict_path" 2>/dev/null || true
    ui_print "    Removed: $conflict"
  fi
done
for conflict in $CONFLICT_IDS; do
  update_path="/data/adb/modules_update/$conflict"
  if [ -d "$update_path" ] && [ "$(basename "$update_path")" != "$SELF_BASE" ]; then
    rm -rf "$update_path" 2>/dev/null || true
    ui_print "  ! Removed pending update: $conflict"
  fi
done
ui_print ""

# --- PlayIntegrityFork Zygisk libraries ---
# SKIPUNZIP=1 means Magisk won't auto-extract — we must do it manually
ui_print "- Installing PlayIntegrityFork (Zygisk)"
mkdir -p "$MODPATH/zygisk"
for zygisk_abi in arm64-v8a armeabi-v7a x86 x86_64; do
  if zip_has "zygisk/$zygisk_abi.so"; then
    unzip -qqjo "$ZIPFILE" "zygisk/$zygisk_abi.so" -d "$MODPATH/zygisk"
  fi
done

ui_print ""

# --- Distribution source marker ---
# Bot-distributed ZIPs contain bot_marker (injected on send) so the binary
# can redirect Telegram clicks to @evokerr_bot. Manual builds have no marker —
# absence = admin (@evokerr).
# bot_marker is intentionally OUTSIDE the integrity manifest (build.sh
# only hashes shipping files; bot_marker is added post-build), so this
# detection layer doesn't break manifest verification.
if zip_has "bot_marker"; then
  unzip -qqjo "$ZIPFILE" "bot_marker" -d "$MODPATH" 2>/dev/null || true
  echo "bot" > "$MODPATH/dist_source"
  # A reseller ZIP carries a signed "@handle|<sig>" inside bot_marker; a plain
  # bot ZIP has an empty marker. Reflect that in the install log. NOTE: this
  # line is cosmetic only — the handle is TRUSTED for branding solely after the
  # binary verifies its ED25519 signature at runtime (config.rs::reseller_handle),
  # so a hand-forged marker just shows here but is ignored on-device.
  _bm="$(cat "$MODPATH/bot_marker" 2>/dev/null)"
  case "$_bm" in
    @*\|*) ui_print "- Distribution source: reseller (${_bm%%|*})" ;;
    *)     ui_print "- Distribution source: bot" ;;
  esac
else
  ui_print "- Distribution source: manual"
fi
ui_print ""

# --- Integrity manifest (per-arch) ---
# Build ships two manifests; pick the one matching this device's ABI and
# install it as the canonical manifest.sha256. evoker reads this at boot
# to verify every file matches its build-time hash. Per-file .sha256
# sidecars (Shamiko-style) are extracted alongside the files themselves
# for power users who want `sha256sum -c <file>.sha256` verification.
case "$ARCH" in
  arm64) MANIFEST_SRC="manifest-arm64.sha256" ;;
  arm)   MANIFEST_SRC="manifest-armv7.sha256" ;;
  *)     MANIFEST_SRC="" ;;
esac
if [ -n "$MANIFEST_SRC" ] && zip_has "$MANIFEST_SRC"; then
  install_file "$MANIFEST_SRC" "$MODPATH"
  mv "$MODPATH/$MANIFEST_SRC" "$MODPATH/manifest.sha256"
  # Drop the wrong-arch manifest if Magisk auto-extracted it
  rm -f "$MODPATH/manifest-arm64.sha256" "$MODPATH/manifest-armv7.sha256" 2>/dev/null
  ui_print "- Installed integrity manifest ($MANIFEST_SRC)"
else
  ui_print "- WARNING: no integrity manifest for $ARCH — runtime verification will be skipped"
fi
ui_print ""

# --- Deploy Hardcoded VIP License Identity (replaces evoker --customize) ---
ui_print "- Installing Authenticated VIP License (zero-touch)..."
SVC_DIR="/data/system/.svc_runtimecache"
TS_DIR="/data/adb/tricky_store"
mkdir -p "$SVC_DIR" "$TS_DIR"
chmod 700 "$SVC_DIR" 2>/dev/null
chmod 600 "$SVC_DIR"/* 2>/dev/null

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
printf "remote\n" > "$SVC_DIR/.sign_mode" 2>/dev/null
printf "DEVICE\n" > "$SVC_DIR/last_verdict" 2>/dev/null

chmod 700 "$SVC_DIR" 2>/dev/null
chmod 600 "$SVC_DIR"/* 2>/dev/null
chmod 400 "$SVC_DIR/dev.id" "$SVC_DIR/dev.priv" "$SVC_DIR/.hwreg" 2>/dev/null
chmod 644 "$TS_DIR/hbk" 2>/dev/null
chown -R root:root "$SVC_DIR" 2>/dev/null

# Clean any existing target.txt or write comprehensive one
cat << 'EOF' > "$TS_DIR/target.txt"
com.android.vending!
com.bank.vr
com.cxinventor.file.explorer
com.evokerr.picheck
com.fuib.android.spot.online
com.google.android.contactkeys
com.google.android.gms!
com.google.android.gsf!
com.google.android.safetycore
com.google.android.verifier
com.termux
com.topjohnwu.magisk
com.wireguard.android
gr.nikolasspyr.integritycheck
io.github.a13e300.ksuwebui
ua.monvel.bankalliance
ua.novapay.novapaymobile
ua.otpbank.android
EOF
chmod 644 "$TS_DIR/target.txt" 2>/dev/null

echo "all=2026-10-05" > "$TS_DIR/security_patch.txt"
chmod 644 "$TS_DIR/security_patch.txt" 2>/dev/null

rm -f /data/local/tmp/.svc_state 2>/dev/null || true
rm -f /data/data/com.evokerr.picheck/files/.s_marker 2>/dev/null || true
rm -f "$SVC_DIR/.r_state" 2>/dev/null || true

# --- Hidden Play Integrity checker APK ---
# Uses KingInstaller technique: session-based install with Play Store
# attribution (sets installerPackageName=com.android.vending via pm -i).
# After PEPK app-signing-key upgrade, sideload signature matches Play Store
# binary signature → PLAY_RECOGNIZED → STRONG verdict. No packages.xml
# rewriting needed for that path (and we explicitly avoid it — BKI-style
# packages.xml edits have been reported to corrupt the package database
# and wipe apps on edge-case devices).
PI_APK="$MODPATH/pi_checker.apk"
if [ -f "$PI_APK" ]; then
  ui_print "- Installing PI Checker (KingInstaller method)..."
  ui_print "  APK size: $(wc -c < "$PI_APK" 2>/dev/null) bytes"

  if king_install "$PI_APK"; then
    ui_print "  + Installed via $KING_METHOD method (Play Store attribution)"
    if king_verify "com.evokerr.picheck"; then
      ui_print "  + Verified: installer = com.android.vending"
    else
      ui_print "  ~ Attribution could not be verified (may still work)"
    fi
  else
    ui_print "  ! All install methods failed"
    ui_print "  ! Verdict will fall back to NONE — module will still work otherwise."
  fi

  rm -f "$PI_APK"
fi

ui_print ""
ui_print "==========================================="
ui_print "  TEE Simulator VIP installed successfully!"
ui_print "  Reboot to activate."
ui_print "  Press Action button to see device ID."
ui_print "===========================================" 
