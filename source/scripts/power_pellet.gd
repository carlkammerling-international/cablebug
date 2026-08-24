extends Node2D
signal powerup

var collected = false


func _on_area_2d_body_entered(body: Node2D) -> void:
	if collected or not body.is_in_group('player'):
		return
	collected = true
	emit_signal("powerup")
	global.score += 50
	$AudioStreamPlayer2D.play()
	visible = false
	$Area2D.set_deferred("monitoring", false)


func respawn() -> void:
	collected = false
	visible = true
	$Area2D.set_deferred("monitoring", true)
