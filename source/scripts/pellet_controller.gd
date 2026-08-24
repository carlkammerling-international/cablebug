extends Node2D
signal win

var won = false


func _process(delta: float) -> void:
	if won:
		return
	
	for pellet in get_children():
		if not pellet.collected:
			return
	
	won = true
	emit_signal("win")


func respawn_all() -> void:
	for pellet in get_children():
		pellet.respawn()
	won = false
