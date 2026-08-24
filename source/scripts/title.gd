extends Node2D

const Leaderboard = preload("res://scripts/services/leaderboard.gd")

var blink = 0.0
var starting = false


func _ready() -> void:
	# Whoever walks up next starts clean, however the last game ended.
	global.score = 0
	global.lives = 3
	global.power_up = false
	global.power_combo = 0
	global.boards_cleared = 0
	
	# Same guard as the level: never inherit an overlay from a previous round.
	if OS.has_feature("web"):
		JavaScriptBridge.eval("if (window.CKContest && window.CKContest.state === 'open') { window.CKContest.close('stale'); }", true)
	
	# "PRESS ANY KEY" / "ARROWS OR WASD" are no help on a phone.
	if DisplayServer.is_touchscreen_available():
		$prompt.text = "TAP TO BEGIN"
		$controls.text = "SWIPE TO MOVE"
	
	_show_best()
	remote_scores.board_fetched.connect(func(_e): _show_best())
	remote_scores.refresh()


func _show_best() -> void:
	var entries = Leaderboard.load_all()
	if entries.is_empty():
		$best.text = ""
	else:
		$best.text = "BEST   %s   %d" % [entries[0]["name"], int(entries[0]["score"])]


func _process(delta: float) -> void:
	blink += delta
	$prompt.modulate.a = 1.0 if fmod(blink, 1.0) < 0.6 else 0.15


func _unhandled_input(event: InputEvent) -> void:
	if starting:
		return
	var pressed = false
	if event is InputEventKey and event.pressed and not event.echo:
		pressed = true
	elif event is InputEventMouseButton and event.pressed:
		pressed = true
	elif event is InputEventJoypadButton and event.pressed:
		pressed = true
	elif event is InputEventScreenTouch and event.pressed:
		pressed = true
	if pressed:
		starting = true
		get_tree().change_scene_to_file("res://scenes/level.tscn")
