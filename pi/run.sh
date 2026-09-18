#!/bin/sh
# Cable Bug kiosk launcher (Raspberry Pi 4B, Raspberry Pi OS 64-bit, X11 session).
# Started at login by ~/.config/autostart/cablebug.desktop.

cd "$HOME/cablebug" || exit 1

# The screen must never sleep. A demo playing to an empty hall is not "input",
# so the desktop would blank the display after ten minutes and the stand would
# look dead. Belt and braces alongside raspi-config's screen blanking setting.
xset s off -dpms 2>/dev/null

# opengl3_es: the Pi has OpenGL ES, not desktop OpenGL. Without this Godot tries
# desktop GL first, fails, and falls back anyway - this just skips the detour.
#
# "until" rather than "while": the game is restarted after a crash, but quitting
# it deliberately (Alt+F4) leaves the desktop up, so someone on the stand can
# change the wi-fi or read the screen. A crash still brings it straight back.
until ./cablebug.arm64 --rendering-driver opengl3_es --fullscreen; do
	sleep 2
done
