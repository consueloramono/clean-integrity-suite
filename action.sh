#!/system/bin/sh
MODDIR="${0%/*}"

# `set +o standalone` intentionally omitted: it is a busybox-ash-only builtin and
# aborts Android's /system/bin/sh (mksh) as an invalid special-builtin option —
# which is why running this script directly produced no output. It is also
# unnecessary, since evoker is a native ELF invoked by absolute path.
unset ASH_STANDALONE 2>/dev/null

"$MODDIR/evoker" --action
exit $?
