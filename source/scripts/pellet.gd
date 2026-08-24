extends Node2D

var collected = false

# Shared across every pellet, so successive pickups alternate between two
# pitches instead of repeating one flat blip.
static var _high_note = false


func _on_area_2d_body_entered(body: Node2D) -> void:
	if collected or not body.is_in_group("player"):
		return
	collect()


# Hidden and switched off rather than freed, so clearing the board can simply
# switch them all back on - and the pickup sound isn't cut short by the node
# disappearing underneath it.
func collect() -> void:
	collected = true
	global.score += 10
	$Sprite0004.visible = false
	$Area2D.set_deferred("monitoring", false)
	
	_high_note = not _high_note
	$AudioStreamPlayer2D.pitch_scale = 1.12 if _high_note else 1.0
	$AudioStreamPlayer2D.play()


func respawn() -> void:
	collected = false
	$Sprite0004.visible = true
	$Area2D.set_deferred("monitoring", true)
