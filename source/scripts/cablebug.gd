extends CharacterBody2D

const GRID_SIZE = 12
const SPEED = 120 # Pixels per second

# The tunnel shifts x by this much. The bounds are past both tunnel mouths -
# the Area2D normally fires long before you reach them.
const WRAP_SPAN = 240.0
const WRAP_LEFT = -34.0
const WRAP_RIGHT = 258.0

@export var current_dir = Vector2.ZERO
var next_dir = Vector2.ZERO
var target_position = position
var just_warped = false
var is_warping = false
var lost = false
var spawn_position = Vector2.ZERO

@onready var rays = {
	Vector2.UP: $rayUp,
	Vector2.DOWN: $rayDown,
	Vector2.LEFT: $rayLeft,
	Vector2.RIGHT: $rayRight
}

func _ready():
	target_position = position
	spawn_position = position


# Back to the start of the maze for the next life, leaving the board untouched.
func _buffer_input() -> void:
	# A swipe is a one-shot, so it is consumed rather than polled like a held key.
	var swipe = touch_input.take_direction()
	if swipe != Vector2.ZERO:
		next_dir = swipe
	
	if Input.is_action_pressed("moveup"): next_dir = Vector2.UP
	if Input.is_action_pressed("movedown"): next_dir = Vector2.DOWN
	if Input.is_action_pressed("moveleft"): next_dir = Vector2.LEFT
	if Input.is_action_pressed("moveright"): next_dir = Vector2.RIGHT


# Safety net. If a tunnel trigger is ever missed - and it can be, if you reach a
# mouth while the previous warp's guard is still up - wrap anyway rather than
# letting the player walk off the map with nothing out there to stop them.
func _keep_in_bounds() -> void:
	if position.x < WRAP_LEFT:
		position.x += WRAP_SPAN
		target_position.x += WRAP_SPAN
	elif position.x > WRAP_RIGHT:
		position.x -= WRAP_SPAN
		target_position.x -= WRAP_SPAN


# Back to the start of the maze for the next life, leaving the board untouched.
func reset_to_spawn() -> void:
	position = spawn_position
	target_position = position
	current_dir = Vector2.ZERO
	next_dir = Vector2.ZERO
	lost = false
	is_warping = false
	just_warped = false
	visible = true
	$AnimatedSprite2D.play("right")

func _process(delta):
	if is_warping:
		return
	if lost:
		# Frozen for READY or the death beat - but keep listening, otherwise a
		# direction pressed during the beat is thrown away and the bug looks
		# unresponsive for the first moment of the new life.
		_buffer_input()
		return
	
	_keep_in_bounds()
	global.bug_pos = position
	
	match current_dir:
		Vector2.UP:
			$AnimatedSprite2D.play("up")
		Vector2.DOWN:
			$AnimatedSprite2D.play("down")
		Vector2.LEFT:
			$AnimatedSprite2D.play("left")
		Vector2.RIGHT:
			$AnimatedSprite2D.play("right")
		Vector2.ZERO:
			$AnimatedSprite2D.stop()
	if not is_warping:
		# 1. Input Buffer: Capture intent at ANY time. 
		# It stays stored in 'next_dir' until it can be executed.
		_buffer_input()

		# 2. Instant U-Turns: Allow the player to instantly reverse direction midway through a tile.
		if next_dir == -current_dir and current_dir != Vector2.ZERO:
			current_dir = next_dir

		# 3. Grid-Intersection Logic
		if position.distance_to(target_position) < 0.1:
			position = target_position # Snap perfectly to the grid tile center
			
			# FIX 1 & 2: Can we turn in the buffered direction?
			if next_dir != Vector2.ZERO and not rays[next_dir].is_colliding():
				current_dir = next_dir
			# If buffered turn is blocked, can we at least keep going straight?
			elif current_dir != Vector2.ZERO and rays[current_dir].is_colliding():
				current_dir = Vector2.ZERO # Straight path is blocked, now we stop.
				
			# Set the next grid target if we have a valid movement direction
			if current_dir != Vector2.ZERO:
				target_position = position + (current_dir * GRID_SIZE)

		# 4. Smooth, pixel-perfect movement execution
	if position != target_position:
		position = position.move_toward(target_position, SPEED * delta)

# SAFETY HEARTBEAT: If we are stopped but we have an input, 
	# force the game to re-check the path.
	if current_dir == Vector2.ZERO and next_dir != Vector2.ZERO:
		if not rays[next_dir].is_colliding():
			current_dir = next_dir
			target_position = position + (current_dir * GRID_SIZE)

func teleport_to_right(offset: Vector2):
	# NOT is_warping: that used to freeze the player for 0.2s on every trip
	# through the tunnel, which read as a stutter on the way out.
	just_warped = true
	
	
	next_dir = Vector2.LEFT
	
	# 1. Update position. Shift the grid target by the SAME offset rather than
	# snapping it to the current position - you are normally mid-tile when you
	# hit the tunnel, and target_position = position would bake that sub-tile
	# offset in permanently, leaving you off-lane and unable to fit down some
	# corridors. 240 is a whole number of tiles, so shifting both keeps the
	# target on a lane centre.
	position += offset
	target_position += offset
	
	# 2. Physics sync
	PhysicsServer2D.body_set_state(get_rid(), PhysicsServer2D.BODY_STATE_TRANSFORM, Transform2D(0, position))
	
	# 3. Two frames is enough to stop the same trigger firing twice; the old
	# 0.2s window was long enough to swallow a legitimate second warp, which
	# let you slip past a tunnel mouth and out of the maze entirely.
	await get_tree().physics_frame
	await get_tree().physics_frame
	just_warped = false

func teleport_to_left(offset: Vector2):
	# NOT is_warping: that used to freeze the player for 0.2s on every trip
	# through the tunnel, which read as a stutter on the way out.
	just_warped = true
	
	
	next_dir = Vector2.RIGHT
	
	# 1. Update position - see teleport_to_right for why the target moves too.
	position -= offset
	target_position -= offset
	
	# 2. Physics sync
	PhysicsServer2D.body_set_state(get_rid(), PhysicsServer2D.BODY_STATE_TRANSFORM, Transform2D(0, position))
	
	# 3. Two frames is enough to stop the same trigger firing twice; the old
	# 0.2s window was long enough to swallow a legitimate second warp, which
	# let you slip past a tunnel mouth and out of the maze entirely.
	await get_tree().physics_frame
	await get_tree().physics_frame
	just_warped = false

func _on_level_warped() -> void:
	position = target_position


func _on_spark_1_lose() -> void:
	lost = true
