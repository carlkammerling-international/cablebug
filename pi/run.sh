#!/bin/sh
# Cable Bug kiosk launcher (Raspberry Pi 4B, Raspberry Pi OS 64-bit, X11 session).
# Started at login by ~/.config/autostart/cablebug.desktop.

cd "$HOME/cablebug" || exit 1

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
until ./cablebug.arm64 --rendering-driver opengl3_es --fullscreen; do
	sleep 2
done
