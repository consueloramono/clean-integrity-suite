#!/system/bin/sh
MODDIR="${0%/*}"

# Stop running processes before clean-up
for proc in evoker TEESimulator supervisor daemon inject; do
  for pid in $(pidof "$proc" 2>/dev/null); do
    kill -9 "$pid" 2>/dev/null
  done
done

# pi-checker (com.evokerr.picheck) is intentionally NOT uninstalled here:
# the APK + its data survive module removal so the user keeps the only app
# this module ever sideloaded.

# VBMeta-Fixer logic is now inside pi-checker (.VbmetaFixerActivity +
# .keyattestation package). No separate APK to uninstall.

# Restore hidden recovery folders
for rdir in TWRP Fox OrangeFox PBRP PitchBlack Recovery; do
  backup="/data/adb/.recovery_backup_${rdir}"
  if [ -d "$backup" ]; then
    mv "$backup" "/sdcard/$rdir" 2>/dev/null || true
  fi
done

# Restore persist props that were overridden at boot
[ -f "$MODDIR/prop_restore.sh" ] && sh "$MODDIR/prop_restore.sh" 2>/dev/null || true

# Clean up upgrade marker and runtime cache
rm -f /data/local/tmp/.tee_upgrade_pending 2>/dev/null || true
rm -rf /data/system/.svc_runtimecache 2>/dev/null || true

# All path-bearing cleanup is delegated to the evoker binary.
"$MODDIR/evoker" --uninstall 2>/dev/null || true
