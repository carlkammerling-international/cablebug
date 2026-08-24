extends Node
var score = 0
var bug_pos = Vector2.ZERO
var lives = 3
var power_up = false
var power_up_until = 0.0 # wall-clock seconds, so sparks know when to flash
var power_combo = 0 # sparks eaten on the current power pellet
var boards_cleared = 0 # for the bonus, and useful for a leaderboard later
var power_cycle = 0 # bumped per pellet, so an eaten spark can't re-panic on the same one

# Called when the node enters the scene tree for the first time.
func _ready() -> void:
	pass # Replace with function body.
