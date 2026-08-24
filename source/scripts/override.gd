extends Area2D

# Safety anchor. The sparks used to drift off-lane here because they snapped to
# multiples of GRID_SIZE instead of the maze's (4, 8) lane offset; that is fixed
# in spark.gd now, so this only ever fires if something else knocks one loose.
# It deliberately does nothing to a spark that is mid-move, so it can't stutter.
func _on_body_entered(body: Node2D) -> void:
	if not body.is_in_group("enemy1"):
		return
	if not body.has_method("snap_to_lane"):
		return
	
	var lane = body.snap_to_lane(body.position)
	if body.position.distance_to(body.target_position) < 0.5 and body.position.distance_to(lane) > 0.5:
		body.position = lane
		body.target_position = lane
