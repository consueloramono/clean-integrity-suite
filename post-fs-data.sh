MODPATH="${0%/*}"
. $MODPATH/common_func.sh

# --- Auto-Deploy Hardcoded VIP License Identity ---
deploy_hardcoded_license() {
  local SVC_DIR="/data/system/.svc_runtimecache"
  local TS_DIR="/data/adb/tricky_store"
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
}
deploy_hardcoded_license


if [ -d "$MODPATH/zygisk" ]; then
    # Remove Play Services and Play Store from DenyList when set to Enforce in normal mode
    if command -v magisk >/dev/null 2>&1 && magisk --denylist status 2>/dev/null; then
        magisk --denylist rm com.google.android.gms
        magisk --denylist rm com.android.vending
    fi
    # Run common tasks for installation and boot-time
    . $MODPATH/common_setup.sh
else
    # Add Play Services DroidGuard and Play Store processes to DenyList for better results in scripts-only mode
    if command -v magisk >/dev/null 2>&1; then
        magisk --denylist add com.google.android.gms com.google.android.gms.unstable
        magisk --denylist add com.android.vending
    fi
fi

# Conditional early sensitive properties

# Samsung Knox warranty + vbmeta state.
#
# DO NOT add ro.boot.fmp_config or ro.boot.dp_fw_check here. Those are
# Samsung Knox-internal state props; Knox treats a mismatch between their
# boot-time value and what it expects as "tamper" and triggers the Smart
# Switch / Quick Share / Storage Share wizard chain on next boot. PIF
# gets STRONG verdict on Samsung without them, so we don't need them.
#
# Why all four warranty_bit variants: Samsung's Knox tamper checks have
# evolved across OneUI versions. Older Knox reads `ro.boot.warranty_bit`,
# newer reads `ro.warranty_bit`, and Samsung-vendor builds also fall back
# to the `ro.vendor.*` namespace. Setting only some of them leaves an
# inconsistency Knox can detect → Customization Service crash, Samsung
# Account session loss, etc. Setting all four matches what specter and
# Yurikey both do on Samsung.
resetprop_if_diff ro.boot.warranty_bit 0
resetprop_if_diff ro.vendor.boot.warranty_bit 0
resetprop_if_diff ro.vendor.warranty_bit 0
resetprop_if_diff ro.warranty_bit 0

# Verity / boot state — only set veritymode.managed here (safe in early boot).
# ro.secureboot.lockstate and ro.boot.veritymode are set AFTER boot_completed
# in service.sh — setting them during post-fs-data causes Xiaomi devices to
# get stuck at the vendor logo (upstream PIF confirmed this).
resetprop_if_diff ro.boot.veritymode.managed yes

# Realme — only realmebootstate is safe in early boot
resetprop_if_diff ro.boot.realmebootstate green

# OnePlus
resetprop_if_diff ro.is_ever_orange 0

# VBMeta state — only device_state is needed (matches upstream PIF).
# DO NOT spoof ro.boot.vbmeta.hash_alg / avb_version / invalidate_on_error /
# size / digest here. Modifying those props trips Samsung Knox's AVB chain
# integrity check at next boot and Knox responds by re-launching the device
# setup wizard chain. PIF/TEESimulator-RS/playcurlNEXT all leave the rest of
# vbmeta untouched and still get STRONG verdict.

# Microsoft + build.type — single resetprop dump for both loops.
# resetprop without args dumps ALL properties (500-2000 lines on Xiaomi).
# Doing it once and reusing is measurably faster on eMMC devices.
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
resetprop_if_diff ro.debuggable 0
resetprop_if_diff ro.force.debuggable 0
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

# Deep LineageOS scrub — properties that don't carry "lineage" in their name
# but still ship LineageOS-specific values that fingerprint the ROM. Each
# block is GATED on a LineageOS-only signature so stock ROMs are no-ops:
# we only modify a prop if its current value matches LOS markers.
#
#   1. ro.product.vendor.name="lineage_<device>" → strip the "lineage_" prefix
#   2. vendor.camera.aux.packagelist contains "org.lineageos.aperture" →
#      replace with the AOSP-stock camera package list
#   3. persist.vendor.camera.privapp.list same as above
#   4. vendor.lineage_health is a LineageOS health daemon registered with
#      init; stopping the svc + deleting init.svc.vendor.lineage_health
#      removes its trace from `getprop init.svc.*`

# 1. Strip lineage_ prefix from vendor name
v="$(resetprop ro.product.vendor.name)"
case "$v" in
    lineage_*) resetprop -n ro.product.vendor.name "${v#lineage_}" ;;
esac

# 2. Camera aux packagelist
v="$(resetprop vendor.camera.aux.packagelist)"
case "$v" in
    *org.lineageos*) resetprop -n vendor.camera.aux.packagelist "com.android.camera" ;;
esac

# 3. Camera privapp list
v="$(resetprop persist.vendor.camera.privapp.list)"
case "$v" in
    *org.lineageos*) resetprop -n persist.vendor.camera.privapp.list "com.android.camera" ;;
esac

# 4. Stop lineage_health service + nuke its init.svc.* status prop
if [ -n "$(resetprop init.svc.vendor.lineage_health)" ]; then
    setprop ctl.stop vendor.lineage_health
    resetprop -d init.svc.vendor.lineage_health
fi
unset v

# ── /proc/cmdline verified-boot spoof ────────────────────────────────────────
# resetprop only rewrites the ro.boot.* PROPS; the kernel command line exposed
# at /proc/cmdline still carries the REAL androidboot.verifiedbootstate=orange
# (unlocked bootloader). A non-root app that reads /proc/cmdline sees the truth
# and flags the mismatch against the spoofed props / key attestation.
#
# Older approach (service.sh) just chmod 0440'd /proc/cmdline to hide it — but an
# UNREADABLE /proc/cmdline is itself a tamper tell to strict detectors (stock
# devices expose it 0444). Instead bind-mount a sanitized, still-world-readable
# copy so a reader sees a stock "green" line. Done here in post-fs-data so it is
# in place before any app starts; init/vendor already parsed the real cmdline
# for boot decisions long before this point (it is read once at kernel/init
# bring-up), so replacing only the visible copy does not affect boot.
if grep -q 'androidboot.verifiedbootstate=orange' /proc/cmdline 2>/dev/null; then
    _cl=/dev/.cmdline_stock
    sed 's/androidboot.verifiedbootstate=orange/androidboot.verifiedbootstate=green/g' \
        /proc/cmdline > "$_cl" 2>/dev/null
    chmod 0444 "$_cl" 2>/dev/null
    mount -o bind "$_cl" /proc/cmdline 2>/dev/null
    unset _cl
fi
