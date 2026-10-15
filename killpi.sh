#!/system/bin/sh
# killpi.sh by @evokerr
#
# Kill the Google Play services DroidGuard and Play Store processes
# (com.google.android.gms.unstable and com.android.vending)

if [ "$USER" != "root" -a "$(whoami 2>/dev/null)" != "root" ]; then
  echo "killpi: need root permissions";
  exit 1;
fi;

killall com.google.android.gms.unstable 2>/dev/null;
killall com.android.vending 2>/dev/null;
