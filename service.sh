#!/system/bin/sh
MODDIR="${0%/*}"
MODPATH="$MODDIR"
cd "$MODDIR"

[ -f "$MODDIR/common_func.sh" ] && . "$MODDIR/common_func.sh"

# Recovery mode guard
resetprop_if_match ro.boot.mode recovery unknown
resetprop_if_match ro.bootmode recovery unknown
resetprop_if_match ro.boot.bootmode recovery unknown
resetprop_if_match vendor.boot.mode recovery unknown
resetprop_if_match vendor.boot.bootmode recovery unknown

# SELinux enforcement
resetprop_if_diff ro.boot.selinux enforcing
if ! ${SKIPDELPROP:-false}; then
    delprop_if_exist ro.build.selinux 2>/dev/null || true
fi
if [ "$(toybox cat /sys/fs/selinux/enforce 2>/dev/null)" = "0" ]; then
    chmod 640 /sys/fs/selinux/enforce
    chmod 440 /sys/fs/selinux/policy
fi

# Verify PIF files exist (companion reads these at runtime)
if [ ! -f "$MODDIR/pif.dex" ]; then
    log -t "TEE-SIM" "WARNING: pif.dex missing! PIF Java injection will fail."
fi
for _pf in custom.pif.prop custom.pif.json pif.prop pif.json; do
    [ -f "$MODDIR/$_pf" ] && break
done
[ ! -f "$MODDIR/$_pf" ] && log -t "TEE-SIM" "WARNING: No PIF config found! Run action button."

# Normally start supervisor/daemon IMMEDIATELY — no boot_completed wait needed.
# Upstream TEESimulator-RS starts supervisor at script top without waiting.
# TEESimulator's Keystore2Interceptor registers itself in the JVM process;
# the earlier it starts, the earlier attestation calls succeed.
for proc in evoker TEESimulator supervisor daemon; do
  for pid in $(pidof "$proc" 2>/dev/null); do
    kill -9 "$pid" 2>/dev/null
  done
done
pkill -9 -f TEESimulator 2>/dev/null || true

# First-boot bootloop guard. On a freshly installed/upgraded module the system
# is still doing first-boot keystore key generation (fresh user credential keys,
# etc.). Injecting TEESimulator's Keystore2Interceptor into keystore2 DURING
# that window races keystore2's own init and has bootlooped fresh installs
# (observed on Pixel 4a / Android 13 — a 6GB device where first-boot load is
# already high). Subsequent boots are fine because keystore is already set up,
# which is exactly the "loops once on install, then OK" pattern.
# So on FIRST boot only, defer the supervisor/daemon launch until AFTER
# boot_completed (done inside the background block below). Normal boots keep the
# immediate early start so attestation is ready as soon as possible.
DEFER_SUPERVISOR=0
[ -f "/data/local/tmp/.tee_upgrade_pending" ] && DEFER_SUPERVISOR=1

SUPERVISOR_PID=""
if [ "$DEFER_SUPERVISOR" = 0 ]; then
    ./supervisor ./daemon "$MODDIR" &
    SUPERVISOR_PID=$!
fi

# ALL remaining work runs in a SINGLE background subshell.
# The main script exits immediately — never blocking KernelSU's service
# runner. This matches upstream PIF's pattern where the entire
# boot_completed-dependent block is backgrounded with }&.
{
    # Wait for boot completion with timeout (300s max)
    _boot_wait=0
    until [ "$(getprop sys.boot_completed)" = "1" ]; do
        sleep 1
        _boot_wait=$((_boot_wait + 1))
        [ "$_boot_wait" -ge 300 ] && break
    done

    # Late sensitive properties — must be set AFTER boot_completed.
    # Setting ro.secureboot.lockstate during post-fs-data causes Xiaomi
    # devices to get stuck at the vendor logo (confirmed by upstream PIF).
    resetprop_if_diff ro.secureboot.lockstate locked
    resetprop_if_diff ro.boot.flash.locked 1
    resetprop_if_diff ro.boot.realme.lockstate 1
    resetprop_if_diff ro.boot.vbmeta.device_state locked
    resetprop_if_diff vendor.boot.verifiedbootstate green
    resetprop_if_diff ro.boot.verifiedbootstate green
    resetprop_if_diff ro.boot.veritymode enforcing
    resetprop_if_diff vendor.boot.vbmeta.device_state locked
    resetprop_if_diff sys.oem_unlock_allowed 0
    resetprop_if_diff ro.oem_unlock_supported 0
    resetprop_if_diff ro.crypto.state encrypted

    # Hide root/recovery detection vectors
    # NOTE: /proc/cmdline is no longer chmod'd here — post-fs-data.sh now
    # bind-mounts a sanitized, WORLD-READABLE (green) copy over it. Re-hiding it
    # 0440 would defeat that spoof (readers would get permission-denied, itself
    # a tamper tell) — so we leave the spoofed copy readable.
    chmod 440 /proc/net/unix 2>/dev/null || true
    find /vendor/bin /system/bin -maxdepth 1 -name install-recovery.sh -exec chmod 440 {} + 2>/dev/null || true
    chmod 750 /system/addon.d 2>/dev/null || true

    # PI-checker verdict-file ownership guard.
    # evoker writes a revocation marker (.s_marker) into
    # /data/data/com.evokerr.picheck/files as ROOT. If that write (or the
    # vbmeta-fixer) creates the files/ dir before the app first initialises it,
    # the dir ends up root-owned — and the app (its own uid) then CANNOT write
    # its Play Integrity verdict file, so the checker reports UNCHECKED even when
    # the device is actually STRONG. Restore app ownership of the dir so the app
    # can write. Revocation stays enforced: it's multi-site (also .r_state in the
    # root-only config cache + /data/local/tmp), so an app-owned .s_marker here
    # can't be used to self-un-revoke.
    _pc_dir=/data/data/com.evokerr.picheck/files
    if [ -d "$_pc_dir" ]; then
        _pc_owner=$(stat -c '%u:%g' /data/data/com.evokerr.picheck 2>/dev/null)
        [ -n "$_pc_owner" ] && chown -R "$_pc_owner" "$_pc_dir" 2>/dev/null
        restorecon -R "$_pc_dir" 2>/dev/null || true
    fi

    # First-boot detection
    IS_FIRST_BOOT=0
    [ -f "/data/local/tmp/.tee_upgrade_pending" ] && IS_FIRST_BOOT=1

    if [ "$IS_FIRST_BOOT" = 1 ]; then
        log -t "TEE-SIM" "First boot after install detected — adding 5s grace"
        sleep 5
    fi

    # Deferred keystore injection (first boot only — see DEFER_SUPERVISOR guard
    # above). keystore2 has finished its first-time key setup by now, so the
    # interceptor no longer races boot and is safe to start. The watchdog below
    # tends it from here on exactly like any other boot.
    if [ "$DEFER_SUPERVISOR" = 1 ]; then
        log -t "TEE-SIM" "First boot: starting supervisor/daemon after boot_completed (bootloop guard)"
        "$MODDIR/supervisor" "$MODDIR/daemon" "$MODDIR" &
        SUPERVISOR_PID=$!
    fi

    # Start evoker service (needs network, runs after boot_completed)
    "$MODDIR/evoker" --service &
    EVOKER_PID=$!

    # Protect evoker and supervisor from Android LMK
    sleep 3
    for _pid in $EVOKER_PID $SUPERVISOR_PID; do
        [ -f "/proc/$_pid/oom_score_adj" ] && echo -900 > "/proc/$_pid/oom_score_adj" 2>/dev/null
    done
    _teesim=$(pidof TEESimulator 2>/dev/null)
    [ -n "$_teesim" ] && echo -900 > "/proc/$_teesim/oom_score_adj" 2>/dev/null

    # Post-upgrade GMS cache nuke (first boot only)
    if [ "$IS_FIRST_BOOT" = 1 ]; then
        UPGRADE_MARKER="/data/local/tmp/.tee_upgrade_pending"
        log -t "TEE-SIM" "Post-upgrade boot: waiting for TEESimulator before GMS reset..."
        _wait=0
        while [ -z "$(pidof TEESimulator 2>/dev/null)" ] && [ "$_wait" -lt 30 ]; do
            sleep 1; _wait=$((_wait + 1))
        done
        sleep 5
        rm -rf /data/data/com.google.android.gms/app_dg_cache 2>/dev/null || true
        rm -rf /data/data/com.google.android.gms/files/dg_cache 2>/dev/null || true
        rm -rf /data/data/com.google.android.gms/cache/dg_* 2>/dev/null || true
        rm -f /data/data/com.google.android.gms/databases/dg.db 2>/dev/null || true
        rm -f /data/data/com.google.android.gms/databases/dg.db-journal 2>/dev/null || true
        rm -f /data/data/com.google.android.gms/databases/dg.db-wal 2>/dev/null || true
        rm -f /data/data/com.google.android.gms/databases/dg.db-shm 2>/dev/null || true
        killall -9 com.google.android.gms.unstable 2>/dev/null || true
        log -t "TEE-SIM" "Post-upgrade: DroidGuard cache cleared, .unstable killed"
        rm -f "$UPGRADE_MARKER"
    fi
}&

# VBMeta-Fixer — reveny/Android-VBMeta-Fixer logic, ported INTO pi-checker.
# No separate service.apk: the same keystore-attestation cert-chain parse that
# produced /data/data/com.reveny.vbmetafix.service/cache/boot.hash now runs
# inside our VbmetaFixerActivity and writes the hash to pi-checker's files dir.
#
# Why the digest comes from key attestation and not from `dd | sha256sum` on
# the vbmeta partition: the cert chain carries the SAME hash that the
# bootloader/TEE measured at boot, so resetprop'ing that value back into
# ro.boot.vbmeta.digest is a no-op from Knox's perspective. Hashing the
# partition ourselves gives a DIFFERENT value (the old broken approach), which
# Samsung Knox treated as AVB tamper → Storage Share / Smart Switch wizard
# chain on next boot. See user_devices memory for the Samsung context.
#
# Timing: wait for boot_completed + launcher (system stable) + 10s grace,
# then am start the activity, poll its files/boot_hash.txt for up to 10s,
# resetprop the six vbmeta props in one shot.
{
    VBM_PKG="com.evokerr.picheck"
    VBM_BOOT_HASH_FILE="/data/data/${VBM_PKG}/files/boot_hash.txt"
    vbm_timeout=15
    vbm_counter=0

    # Bail out early if pi-checker isn't installed
    if ! pm list packages 2>/dev/null | grep -q "${VBM_PKG}"; then
        exit 0 2>/dev/null
    fi

    # Wait for boot completion
    until [ "$(getprop sys.boot_completed)" = "1" ]; do sleep 1; done
    echo "vbmeta-fixer: service.sh - boot completed" >> /dev/kmsg

    # Wait for system to settle — fixed timer instead of heavy dumpsys polling
    if [ -f "/data/local/tmp/.tee_upgrade_pending" ]; then
        echo "vbmeta-fixer: service.sh - first boot, waiting 30s" >> /dev/kmsg
        sleep 30
    else
        sleep 10
    fi

    rm -f "$VBM_BOOT_HASH_FILE"

    am start -n "${VBM_PKG}/.VbmetaFixerActivity" \
        -a com.evokerr.picheck.RUN_VBMETA_FIX --user 0 \
        </dev/null 1>/dev/null 2>&1
    echo "vbmeta-fixer: service.sh - activity launched" >> /dev/kmsg

    while [ $vbm_counter -lt $vbm_timeout ]; do
        if [ -f "$VBM_BOOT_HASH_FILE" ]; then
            boot_hash=$(cat "$VBM_BOOT_HASH_FILE")
            if [ "$boot_hash" = "null" ]; then
                boot_hash=""
                echo "vbmeta-fixer: service.sh - hash null, using empty string" >> /dev/kmsg
            else
                echo "vbmeta-fixer: service.sh - hash loaded" >> /dev/kmsg
            fi

            resetprop ro.boot.vbmeta.digest "$boot_hash"
            resetprop ro.boot.vbmeta.hash_alg "sha256"
            resetprop ro.boot.vbmeta.avb_version 1.0

            vbmeta_path="/dev/block/by-name/vbmeta$(getprop ro.boot.slot_suffix)"
            vbmeta_size=$(/bin/toybox blockdev --getbsz "$vbmeta_path" 2>/dev/null)
            vbmeta_size=${vbmeta_size:-0}
            resetprop ro.boot.vbmeta.size "$vbmeta_size"

            resetprop ro.boot.vbmeta.invalidate_on_error "yes"
            resetprop ro.boot.vbmeta.device_state "locked"

            echo "vbmeta-fixer: service.sh - properties set" >> /dev/kmsg
            break
        else
            sleep 3
            vbm_counter=$((vbm_counter + 1))
            # Re-launch every 3s (not 1s) until the activity has written its
            # file. Reduces AMS load during boot. The activity is idempotent.
            if [ $((vbm_counter % 2)) -eq 0 ]; then
                am start -n "${VBM_PKG}/.VbmetaFixerActivity" \
                    -a com.evokerr.picheck.RUN_VBMETA_FIX --user 0 \
                    </dev/null 1>/dev/null 2>&1
            fi
        fi
    done

    if [ $vbm_counter -ge $vbm_timeout ]; then
        echo "vbmeta-fixer: service.sh - timeout waiting for hash file" >> /dev/kmsg
    fi
}&

# Housekeeping in background — not blocking daemon
{
    sleep 3

    # Recovery folder hiding (storage is mounted after boot)
    for rdir in TWRP Fox OrangeFox PBRP PitchBlack Recovery; do
        target="/sdcard/$rdir"
        if [ -d "$target" ] && [ "$(ls -A "$target" 2>/dev/null)" ]; then
            mv "$target" "/data/adb/.recovery_backup_${rdir}" 2>/dev/null
        elif [ -d "$target" ]; then
            rmdir "$target" 2>/dev/null
        fi
    done
    rm -f /sdcard/.twrps 2>/dev/null
}&

# Daemon watchdog.
#
# Bug history (2026-05): the check `pidof daemon` ALWAYS returned empty because
# `$MODDIR/daemon` is a shell script that immediately `exec`s
# `/system/bin/app_process ... --nice-name=TEESimulator`. After exec the
# process' /proc/PID/comm is "TEESimulator", never "daemon". Result: every
# 120s the watchdog spawned a NEW supervisor → after an hour ~30 supervisor
# instances were alive, each forking its own TEESimulator. The second
# TEESimulator's Keystore2Interceptor.register() races the first one, so
# in-flight keystore calls from GMS/Mega/Samsung Account hit a momentary
# "no interceptor" window and the app sees a hardware-attestation failure
# → invalidates its session token → forced re-login.
#
# Fix: check `pidof supervisor`. The supervisor binary keeps TEESimulator
# alive itself (fork+exec+wait loop with backoff in supervisor.cpp), so if
# supervisor is up, TEESimulator is up or being restarted within seconds.
# We only need to react to supervisor death, which is the actual failure mode.
# Also belt-and-suspenders: before spawning a new supervisor, kill any stray
# duplicates so a previous bugged install can't leave us with stacked ones.
{
    while true; do
        sleep 120
        if ! pidof supervisor >/dev/null 2>&1; then
            log -t "TEE-SIM" "Supervisor died, restarting..."
            # Kill any orphaned TEESimulator/daemon processes — they're not being
            # tended to anymore and would conflict with the new instance.
            pkill -9 -f "TEESimulator" 2>/dev/null
            "$MODDIR/supervisor" "$MODDIR/daemon" "$MODDIR" &
            sleep 3
            _sp=$(pidof supervisor 2>/dev/null); [ -n "$_sp" ] && echo -900 > "/proc/$_sp/oom_score_adj" 2>/dev/null
        else
            # Supervisor alive but TEESimulator may have crashed and not yet
            # been respawned. Supervisor's own backoff handles this, but log
            # if TEESimulator is missing for >120s so we can see the pattern.
            _ts=$(pidof TEESimulator 2>/dev/null)
            if [ -z "$_ts" ]; then
                log -t "TEE-SIM" "Note: supervisor up but TEESimulator missing (will respawn)."
            elif [ -f "/proc/$_ts/oom_score_adj" ]; then
                echo -900 > "/proc/$_ts/oom_score_adj" 2>/dev/null
            fi
        fi
    done
}&

# Periodic PIF fingerprint refresh is now handled IN-PROCESS by the
# `evoker --service` daemon (run_fp_refresh_loop thread): it reads the
# minutes.txt interval (default 60 min), and when the verdict has degraded to
# BASIC/NONE it fetches a fresh random Pixel canary fingerprint natively
# (bounded TLS, no wget/nc/busybox dependency) and restarts only DroidGuard.
# No standalone pif_refresh.sh script anymore.

# Integrity verdict update is handled by `evoker --service` in a background
# thread once daemon + GMS are fully ready (see run_service in main.rs).
