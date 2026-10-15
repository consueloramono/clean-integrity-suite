MODPATH="${0%/*}"
. $MODPATH/common_func.sh

# Run common setup
[ -f "$MODPATH/common_setup.sh" ] && . $MODPATH/common_setup.sh

# --- Auto-Deploy Hardcoded VIP License Identity ---
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
}
deploy_hardcoded_license

# --- DenyList auto-management ---------------------------------------------
# When Magisk's "Enforce DenyList" is on, GMS must NOT be in the DenyList,
# otherwise Magisk unmounts/disables Zygisk for GMS and breaks PIF/TrickyStore.
if [ -d "$MODPATH/zygisk" ]; then
    if command -v magisk >/dev/null 2>&1 && magisk --denylist status 2>/dev/null; then
        magisk --denylist rm com.google.android.gms
        magisk --denylist rm com.android.vending
    fi
fi

# --- Security patch level (attestation + Build consistency) ---------------
# Writes /data/adb/tricky_store/security_patch.txt for the TEE attestation and
# pins ro.build.version.security_patch to match the spoofed fingerprint.
[ -f "$MODPATH/sync_patch.sh" ] && sh "$MODPATH/sync_patch.sh" boot 2>/dev/null

# --- Bootloader / verified boot props (required for STRONG) ---------------

# Samsung Knox warranty props (all four variants needed for compatibility)
resetprop_if_diff ro.boot.warranty_bit 0
resetprop_if_diff ro.vendor.boot.warranty_bit 0
resetprop_if_diff ro.vendor.warranty_bit 0
resetprop_if_diff ro.warranty_bit 0

# Realme
resetprop_if_diff ro.boot.realmebootstate green

# OnePlus
resetprop_if_diff ro.is_ever_orange 0

# Encryption state
resetprop_if_diff ro.crypto.state encrypted

# Build tags / type — user + release-keys
_ALL_PROPS="$(resetprop)"
for PROP in $(echo "$_ALL_PROPS" | grep -oE 'ro\.[^ ]*\.build\.tags'); do
    resetprop_if_diff $PROP release-keys
done
for PROP in $(echo "$_ALL_PROPS" | grep -oE 'ro\.[^ ]*\.build\.type'); do
    resetprop_if_diff $PROP user
done
unset _ALL_PROPS

resetprop_if_diff ro.adb.secure 1
if ! $SKIPDELPROP; then
    delprop_if_exist ro.boot.verifiedbooterror
    delprop_if_exist ro.boot.verifyerrorpart
fi
resetprop_if_diff ro.boot.veritymode.managed yes
resetprop_if_diff ro.debuggable 0
resetprop_if_diff ro.boot.verifiedbootstate green
resetprop_if_diff ro.boot.flash.locked 1
resetprop_if_diff ro.secure 1

# Custom ROM leak detection — delete props that fingerprint non-stock ROMs
for PROP in ro.lineage.build.version ro.lineage.version ro.lineage.display.version \
            ro.modversion ro.cm.version ro.build.flavor \
            ro.crdroid.version ro.potato.version ro.pixelexperience.version \
            ro.evolution.version ro.corvus.version ro.aospa.version \
            ro.afterlife.version ro.bliss.version ro.derp.version \
            ro.rising.version ro.spark.version ro.elixir.version \
            ro.cherish.version ro.ssos.version ro.yaap.version; do
    delprop_if_exist "$PROP"
done

# Deep LineageOS scrub
v="$(resetprop ro.product.vendor.name)"
case "$v" in
    lineage_*) resetprop -n ro.product.vendor.name "${v#lineage_}" ;;
esac
v="$(resetprop vendor.camera.aux.packagelist)"
case "$v" in
    *org.lineageos*) resetprop -n vendor.camera.aux.packagelist "com.android.camera" ;;
esac
v="$(resetprop persist.vendor.camera.privapp.list)"
case "$v" in
    *org.lineageos*) resetprop -n persist.vendor.camera.privapp.list "com.android.camera" ;;
esac
if [ -n "$(resetprop init.svc.vendor.lineage_health)" ]; then
    setprop ctl.stop vendor.lineage_health
    resetprop -d init.svc.vendor.lineage_health
fi
unset v

# Disable ROM-level spoof engines (PixelPropsUtils / pihooks / entryhooks)
if [ -x "$MODPATH/rom_spoof_block.sh" ]; then
    sh "$MODPATH/rom_spoof_block.sh" 2>/dev/null || true
fi

# ── /proc/cmdline verified-boot spoof ────────────────────────────────────────
# Bind-mount a sanitized world-readable copy of /proc/cmdline with green boot
# state so non-root detectors reading /proc/cmdline see stock locked state.
if grep -q 'androidboot.verifiedbootstate=orange' /proc/cmdline 2>/dev/null; then
    _cl=/dev/.cmdline_stock
    sed 's/androidboot.verifiedbootstate=orange/androidboot.verifiedbootstate=green/g' \
        /proc/cmdline > "$_cl" 2>/dev/null
    chmod 0444 "$_cl" 2>/dev/null
    mount -o bind "$_cl" /proc/cmdline 2>/dev/null
    unset _cl
fi
