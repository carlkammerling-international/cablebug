extends Node

# Swipe-to-steer for touch devices.
#
# Movement is grid-based with a direction buffer, so a swipe maps cleanly onto
# the same buffer the keyboard and gamepad already feed - there's one input path
# rather than three. Swipes are preferred over an on-screen d-pad because they
# cost no screen space, which matters in landscape where there is none to spare.

# Distance (in viewport units, so ~5% of the 320-unit width) before a drag
# counts as a swipe rather than a wobbly tap.
const SWIPE_MIN = 16.0

var _origin = Vector2.ZERO
var _tracking = false
var _moved = false
var _pending_dir = Vector2.ZERO
var _pending_tap = false


func _input(event: InputEvent) -> void:
	if event is InputEventScreenTouch:
		if event.pressed:
			_origin = event.position
			_tracking = true
			_moved = false
		else:
			# A finger that never travelled far is a tap, not a swipe.
			if _tracking and not _moved:
				_pending_tap = true
			_tracking = false
	
	elif event is InputEventScreenDrag and _tracking:
		var delta = event.position - _origin
		if delta.length() >= SWIPE_MIN:
			_pending_dir = _dominant_axis(delta)
			_moved = true
			# Re-anchor so one finger can keep steering without lifting.
			_origin = event.position


func _dominant_axis(v: Vector2) -> Vector2:
	if absf(v.x) > absf(v.y):
		return Vector2.RIGHT if v.x > 0.0 else Vector2.LEFT
	return Vector2.DOWN if v.y > 0.0 else Vector2.UP


# Both of these consume what they return, so one gesture produces one action.
func take_direction() -> Vector2:
	var d = _pending_dir
	_pending_dir = Vector2.ZERO
	return d


func take_tap() -> bool:
	var t = _pending_tap
	_pending_tap = false
	return t


func has_touch() -> bool:
	return DisplayServer.is_touchscreen_available()
