#!/bin/sh
# Cable Bug kiosk launcher (Raspberry Pi 4B, Raspberry Pi OS 64-bit, X11 session).
# Started at login by ~/.config/autostart/cablebug.desktop.

cd "$HOME/cablebug" || exit 1

# Keep the last run's output, so a stand that comes up wrong can be diagnosed
# after the fact rather than only while watching it. Trimmed when it gets long,
# since this runs for days at a time.
LOG="$HOME/cablebug/run.log"
if [ -f "$LOG" ] && [ "$(wc -c < "$LOG")" -gt 5000000 ]; then
	tail -c 1000000 "$LOG" > "$LOG.tmp" && mv "$LOG.tmp" "$LOG"
fi
exec >> "$LOG" 2>&1
echo "--- starting $(date) session=${XDG_SESSION_TYPE:-unknown} display=${DISPLAY:-unset}"

# Frame rate readout, for checking the kiosk as it actually runs rather than a
# copy started by hand - which is a different thing, as two instances at once
# will both crawl. Turn on with: touch ~/cablebug/DEBUG_FPS  (then restart), and
# read it back with: grep fps= ~/cablebug/run.log | tail -20
EXTRA=""
if [ -f "$HOME/cablebug/DEBUG_FPS" ]; then
	EXTRA="-- --fps"
fi

# Always draw through X11. Godot 4.6.2's Wayland driver crashes on launch here
# (godotengine/godot#118157), so if the session ever comes back up as Wayland -
# switching on desktop auto-login can do that - this goes through Xwayland
# instead of crash-looping.
export DISPLAY="${DISPLAY:-:0}"

# The screen must never sleep. A demo playing to an empty hall is not "input",
# so the desktop would blank the display after ten minutes and the stand would
# look dead. Belt and braces alongside raspi-config's screen blanking setting.
xset s off -dpms 2>/dev/null

# Force 1080p60. A Pi 4 brings a 4K screen up at 30Hz by default, which caps the
# game at 30fps and costs far more to draw; xrandr changes made by hand do not
# survive a reboot, so it is done here every launch. The output name is looked up
# rather than hard-coded, so this works whichever HDMI port is used.
OUTPUT=$(xrandr | awk '/ connected/{print $1; exit}')
if [ -n "$OUTPUT" ]; then
	xrandr --output "$OUTPUT" --mode 1920x1080 --rate 60 2>/dev/null
fi

# opengl3_es: the Pi has OpenGL ES, not desktop OpenGL. Without this Godot tries
# desktop GL first, fails, and falls back anyway - this just skips the detour.
#
# "until" rather than "while": the game is restarted after a crash, but quitting
# it deliberately (Alt+F4) leaves the desktop up, so someone on the stand can
# change the wi-fi or read the screen. A crash still brings it straight back.
until ./cablebug.arm64 --display-driver x11 --rendering-driver opengl3_es --fullscreen $EXTRA; do
	echo "--- game exited with an error, restarting $(date)"
	sleep 2
done
