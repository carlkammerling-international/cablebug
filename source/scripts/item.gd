extends Node2D

signal picked_up(value: int, at: Vector2)

var value: int
var collected = false


func _on_timer_timeout() -> void:
	$Area2D.set_deferred("monitoring", true)
	var item = randi_range(1, 3)
	
	match item:
		1:
			$Sprite2D.play("holesaw")
			value = 200
		2:
			$Sprite2D.play("redline")
			value = 500
		3:
			$Sprite2D.play("sporck")
			value = 1000
	$Sprite2D.visible = true


func _on_area_2d_body_entered(body: Node2D) -> void:
	if collected or not body.is_in_group('player'):
		return
	collected = true
	global.score += value
	$Sprite2D.visible = false
	$Area2D.set_deferred("monitoring", false)
	# The node sticks around (hidden) rather than being freed, so the sound gets
	# to finish rather than being cut off mid-blip.
	$AudioStreamPlayer2D.play()
	picked_up.emit(value, global_position)


# A fresh board gets a fresh item, on the same timer as the first one.
func respawn() -> void:
	collected = false
	$Sprite2D.visible = false
	$Area2D.set_deferred("monitoring", false)
	$Timer.start()
