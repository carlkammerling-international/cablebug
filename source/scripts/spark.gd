class_name base_enemy
extends CharacterBody2D

enum Personality { BLINKY, PINKY, INKY, CLYDE }
enum State { WAITING, LEAVING, HUNTING, FRIGHTENED, EATEN, ENTERING }

const GRID_SIZE = 12
# The maze lanes sit on x % 12 == 4, y % 12 == 8 - NOT on bare multiples of 12.
# Probing the collision map with a 12x12 box finds 193 open cells on this grid
# and only 4 on the (0,0) grid, so snapping to plain multiples of GRID_SIZE
# drops a spark inside a wall.
const GRID_ORIGIN = Vector2(4, 8)
const SPEED = 80 # 2/3 of the player's 120 - forgiving for first-timers at a stand
const FRIGHTENED_SPEED = 50 # panicking sparks should be easy to run down
const EYES_SPEED = 110 # hurrying home, but no longer darting across the maze
const RESPAWN_DELAY = 3.0

const FRIGHTENED_TINT = Color(0.15, 0.2, 0.8) # deep navy, well clear of Inky's cyan
const EYES_BRIGHT = Color(1, 1, 1, 1)
const EYES_DIM = Color(1, 1, 1, 0.15)

# The warp tunnel shifts x by exactly this much (see level.gd), so this is the
# distance to beat when working out whether going the "wrong" way is shorter.
const WRAP_WIDTH = 240.0

const HOUSE_DOOR = Vector2(112, 128) # inside the house, directly under the door
const HOUSE_EXIT = Vector2(112, 104) # the lane above the house

# Seconds per phase, alternating scatter/chase and looping forever. The arcade
# ramps into permanent chase; for a stand this keeps giving people breathing
# room no matter how long they last.
const PHASES = [10.0, 12.0]

var lost = false
var just_warped = false
var is_warping = false
var current_dir = Vector2.ZERO
var target_position = position
signal lose
signal eaten(value: int, at: Vector2)

@export var personality: Personality = Personality.BLINKY
@export var player: Node2D # Drag and drop Pac-Man here in the Inspector
@export var blinky: Node2D # Inky steers off Blinky's position, so it needs it
@export var scatter_corner := Vector2(208, 20)
@export var spawn_delay := 0.0
@export var starts_in_house := false
@export var normal_tint: Color = Color.WHITE

# The maze never changes, so every spark shares one lane map, built the first
# time a spark actually needs to find its way home.
static var lane_cells: Dictionary = {}
static var graph_ready := false

var state = State.HUNTING
var wait_left = 0.0
var phase_index = 0
var phase_left = PHASES[0]
var scattering = true
var exempt_cycle = -1 # power pellet this spark sat out (eaten, or safe in the house)
var spawn_position = Vector2.ZERO
var spawn_in_house = false # authored value; _enter_house flips starts_in_house

@onready var rays = {
	Vector2.UP: $rayUp,
	Vector2.DOWN: $rayDown,
	Vector2.LEFT: $rayLeft,
	Vector2.RIGHT: $rayRight
}

func _ready():
	_update_look()
	position = snap_to_lane(position)
	target_position = position
	spawn_position = position
	spawn_in_house = starts_in_house
	wait_left = spawn_delay
	if spawn_delay > 0.0 or starts_in_house:
		state = State.WAITING
	else:
		state = State.HUNTING
		current_dir = Vector2.LEFT

# Put this spark back as it started, without rebuilding the level - so the
# pellets the player has already cleared survive a death.
func reset_to_spawn() -> void:
	position = spawn_position
	target_position = position
	current_dir = Vector2.ZERO
	lost = false
	visible = true
	is_warping = false
	just_warped = false
	exempt_cycle = -1
	phase_index = 0
	phase_left = PHASES[0]
	scattering = true
	starts_in_house = spawn_in_house
	wait_left = spawn_delay
	if spawn_delay > 0.0 or starts_in_house:
		state = State.WAITING
	else:
		state = State.HUNTING
		current_dir = Vector2.LEFT
	_update_look()


# Rounds to the nearest lane centre, honouring the maze's (4, 8) offset.
func snap_to_lane(p: Vector2) -> Vector2:
	return ((p - GRID_ORIGIN) / GRID_SIZE).round() * GRID_SIZE + GRID_ORIGIN

func get_wrapped_distance(pos1: Vector2, pos2: Vector2) -> float:
	var dx = abs(pos1.x - pos2.x)
	var dy = abs(pos1.y - pos2.y)
	
	# If the horizontal distance is greater than half the wrap width,
	# it means going through the tunnel is actually shorter!
	if dx > WRAP_WIDTH / 2.0:
		dx = WRAP_WIDTH - dx
	
	return sqrt(dx * dx + dy * dy)

func player_dir() -> Vector2:
	if player and player.current_dir != Vector2.ZERO:
		return player.current_dir
	return Vector2.RIGHT

# Each personality is just a different answer to "which tile am I aiming at?".
# Everything below this is shared, which is what keeps them feeling like a team
# rather than four copies of the same spark.
func get_target() -> Vector2:
	if not player:
		return position
	if scattering:
		return scatter_corner
	
	match personality:
		Personality.PINKY:
			# Aims four tiles AHEAD of the player, so it cuts corners and ambushes.
			return player.position + player_dir() * 4 * GRID_SIZE
		Personality.INKY:
			# Takes the tile two ahead of the player, then doubles the vector from
			# Blinky through it - so it pincers whenever Blinky is closing in.
			var pivot = player.position + player_dir() * 2 * GRID_SIZE
			var anchor = blinky.position if blinky else position
			return pivot + (pivot - anchor)
		Personality.CLYDE:
			# Bold at a distance, but loses its nerve and bolts home once it gets
			# within eight tiles.
			if get_wrapped_distance(position, player.position) > 8 * GRID_SIZE:
				return player.position
			return scatter_corner
		_:
			# Blinky: straight at the player, relentlessly.
			return player.position

func calculate_best_direction() -> Vector2:
	if not player:
		return Vector2.ZERO
	
	# Force all raycasts to update from our newly snapped position right now!
	for ray in rays.values():
		ray.force_raycast_update()
	
	var target = get_target()
	var best_dir = Vector2.ZERO
	var shortest_distance = INF
	
	for dir in rays.keys():
		# Sparks aren't allowed to double back mid-corridor.
		if dir == -current_dir and current_dir != Vector2.ZERO:
			continue
		if rays[dir].is_colliding():
			continue
		
		var potential_next_step = position + (dir * GRID_SIZE)
		var distance_to_target = get_wrapped_distance(potential_next_step, target)
		
		if distance_to_target < shortest_distance:
			shortest_distance = distance_to_target
			best_dir = dir
	
	# Dead end: turning round is the only legal move left.
	if best_dir == Vector2.ZERO and current_dir != Vector2.ZERO:
		if not rays[-current_dir].is_colliding():
			best_dir = -current_dir
	
	return best_dir

func _process(delta):
	if lost:
		return
	
	# Sparks inside the house are immune to energizers, as in the arcade: one that
	# is penned in or walking out when a pellet is eaten emerges in its normal
	# state, not blue, and stays that way for the rest of that pellet.
	if global.power_up and (state == State.WAITING or state == State.LEAVING):
		exempt_cycle = global.power_cycle
	
	# A power pellet flips hunting sparks into a panic, and ends it when it wears
	# off. Sparks still penned in, on their way out, or already eaten are exempt.
	if state == State.HUNTING and should_panic():
		state = State.FRIGHTENED
		reverse() # the arcade tell that the pellet actually did something
	elif state == State.FRIGHTENED and not should_panic():
		state = State.HUNTING
	
	if state != State.FRIGHTENED:
		_keep_in_bounds()
	_advance_phase(delta) # the arcade freezes the phase clock during a frenzy
	
	match state:
		State.WAITING:
			wait_left -= delta
			if wait_left <= 0.0:
				if starts_in_house:
					state = State.LEAVING
				else:
					state = State.HUNTING
					current_dir = Vector2.LEFT
		State.LEAVING:
			_leave_house(delta)
		State.HUNTING:
			_hunt(delta)
		State.FRIGHTENED:
			_flee(delta)
		State.EATEN:
			_return_home(delta)
		State.ENTERING:
			_enter_house(delta)
	
	_update_look()

# Walk to the door column, then straight up through it. Movement is positional
# (never move_and_slide), so the body passes the door freely; it is only the rays
# that treat the door as solid, and those are ignored here. That makes the door
# one-way: a spark can leave, but once HUNTING its rays see the door as a wall,
# so it can never wander back into the house and get stuck.
func _leave_house(delta):
	var goal = HOUSE_DOOR
	if abs(position.x - HOUSE_DOOR.x) < 0.5:
		goal = HOUSE_EXIT
	position = position.move_toward(goal, SPEED * delta)
	
	if position.distance_to(HOUSE_EXIT) < 0.5:
		position = snap_to_lane(position)
		target_position = position
		current_dir = Vector2.LEFT
		state = State.FRIGHTENED if should_panic() else State.HUNTING

func _hunt(delta):
	# Grid-Intersection Logic (Matches player code structure)
	if position.distance_to(target_position) < 0.1:
		position = snap_to_lane(position) # Snap perfectly to the lane centre
		
		current_dir = calculate_best_direction()
		
		if current_dir != Vector2.ZERO:
			target_position = position + (current_dir * GRID_SIZE)
		else:
			target_position = position
	
	if position != target_position:
		position = position.move_toward(target_position, SPEED * delta)

# Frightened sparks stop hunting and just bolt at random, arcade style.
# Edible only while a pellet is live AND this spark hasn't already sat that
# particular pellet out - by being eaten on it, or by being in the house for it.
func should_panic() -> bool:
	return global.power_up and exempt_cycle != global.power_cycle

# Same tunnel safety net the player has, so a spark can't be lost off-map.
func _keep_in_bounds() -> void:
	if position.x < -34.0:
		position.x += WRAP_WIDTH
		target_position.x += WRAP_WIDTH
	elif position.x > 258.0:
		position.x -= WRAP_WIDTH
		target_position.x -= WRAP_WIDTH


# Turn on the spot. The tile we came from is always a legal lane centre, so
# this can't strand a spark off-grid halfway down a corridor.
func reverse() -> void:
	if current_dir == Vector2.ZERO:
		return
	
	var came_from = target_position - (current_dir * GRID_SIZE)
	current_dir = -current_dir
	
	if came_from.distance_to(position) < 0.1:
		# Sitting exactly on a tile centre: backing up to "where we came from"
		# would be a no-op, and the next decision tick would just re-roll a
		# direction, so the turn-around would never be seen. Step back a whole
		# tile instead, if that way is open.
		rays[current_dir].force_raycast_update()
		if rays[current_dir].is_colliding():
			return
		came_from = position + (current_dir * GRID_SIZE)
	
	target_position = came_from


func _flee(delta):
	if position.distance_to(target_position) < 0.1:
		position = snap_to_lane(position)
		current_dir = random_direction()
		if current_dir != Vector2.ZERO:
			target_position = position + (current_dir * GRID_SIZE)
		else:
			target_position = position
	
	if position != target_position:
		position = position.move_toward(target_position, FRIGHTENED_SPEED * delta)

func random_direction() -> Vector2:
	for ray in rays.values():
		ray.force_raycast_update()
	
	var options = []
	for dir in rays.keys():
		if dir == -current_dir and current_dir != Vector2.ZERO:
			continue
		if not rays[dir].is_colliding():
			options.append(dir)
	
	if options.is_empty():
		if current_dir != Vector2.ZERO and not rays[-current_dir].is_colliding():
			return -current_dir
		return Vector2.ZERO
	return options[randi() % options.size()]

func world_to_cell(p: Vector2) -> Vector2i:
	var c = (p - GRID_ORIGIN) / GRID_SIZE
	return Vector2i(roundi(c.x), roundi(c.y))

func cell_to_world(c: Vector2i) -> Vector2:
	return Vector2(c) * GRID_SIZE + GRID_ORIGIN

# Probe the collision world once for every open lane cell. The box is small
# because a few corridors are only ~11px wide, narrower than a spark.
func build_lane_graph() -> void:
	if graph_ready:
		return
	graph_ready = true
	
	var excl = []
	for e in get_tree().get_nodes_in_group("enemy1"):
		excl.append(e.get_rid())
	
	var box = RectangleShape2D.new()
	box.size = Vector2(6, 6)
	var q = PhysicsShapeQueryParameters2D.new()
	q.shape = box
	q.collision_mask = 16
	q.exclude = excl
	
	var space = get_world_2d().direct_space_state
	for cy in range(0, 22):
		for cx in range(0, 20):
			var cell = Vector2i(cx, cy)
			q.transform = Transform2D(0, cell_to_world(cell))
			if space.intersect_shape(q, 1).is_empty():
				lane_cells[cell] = true

# Breadth-first, so eyes always find the shortest legal way back rather than
# getting wedged in a dead end the way greedy chasing would.
func next_step_home() -> Vector2:
	var start = world_to_cell(position)
	var goal = world_to_cell(HOUSE_EXIT)
	if not lane_cells.has(start) or not lane_cells.has(goal) or start == goal:
		return Vector2.ZERO
	
	var came = {start: start}
	var queue = [start]
	var found = false
	while not queue.is_empty():
		var cur = queue.pop_front()
		if cur == goal:
			found = true
			break
		for d in [Vector2i.UP, Vector2i.DOWN, Vector2i.LEFT, Vector2i.RIGHT]:
			var nxt = cur + d
			if lane_cells.has(nxt) and not came.has(nxt):
				came[nxt] = cur
				queue.append(nxt)
	
	if not found:
		return Vector2.ZERO
	
	var node = goal
	while came[node] != start:
		node = came[node]
	return Vector2(node - start)

func _return_home(delta):
	if position.distance_to(target_position) < 0.1:
		position = snap_to_lane(position)
		if position.distance_to(HOUSE_EXIT) < 0.5:
			state = State.ENTERING
			return
		
		var step = next_step_home()
		if step == Vector2.ZERO:
			# Off the lane map (caught out in the warp tunnel, say) - drift
			# straight at the house rather than stalling forever.
			position = position.move_toward(HOUSE_EXIT, EYES_SPEED * delta)
			target_position = position
			if position.distance_to(HOUSE_EXIT) < 0.5:
				state = State.ENTERING
			return
		
		current_dir = step
		target_position = position + (current_dir * GRID_SIZE)
	
	if position != target_position:
		position = position.move_toward(target_position, EYES_SPEED * delta)

func _enter_house(delta):
	position = position.move_toward(HOUSE_DOOR, EYES_SPEED * delta)
	if position.distance_to(HOUSE_DOOR) < 0.5:
		position = HOUSE_DOOR
		target_position = position
		current_dir = Vector2.ZERO
		starts_in_house = true # even Blinky rebuilds itself in the house
		wait_left = RESPAWN_DELAY
		state = State.WAITING

func _update_look():
	match state:
		State.FRIGHTENED:
			var left = global.power_up_until - Time.get_ticks_msec() / 1000.0
			# Flash white over the last stretch as a "time's nearly up" warning.
			if left < 1.5 and fmod(left, 0.4) < 0.2:
				$AnimatedSprite2D.modulate = Color.WHITE
			else:
				$AnimatedSprite2D.modulate = FRIGHTENED_TINT
		State.EATEN, State.ENTERING:
			# Blink hard - plain translucency was too easy to miss.
			var on = fmod(Time.get_ticks_msec() / 1000.0, 0.24) < 0.12
			$AnimatedSprite2D.modulate = EYES_BRIGHT if on else EYES_DIM
		_:
			$AnimatedSprite2D.modulate = normal_tint

func _get_eaten():
	# 200, 400, 800, 1600 for successive sparks on one power pellet.
	var value = 200 * int(pow(2, min(global.power_combo, 3)))
	global.score += value
	global.power_combo += 1
	exempt_cycle = global.power_cycle
	
	build_lane_graph()
	position = snap_to_lane(position)
	target_position = position
	current_dir = Vector2.ZERO
	state = State.EATEN
	
	# Emitted last, so the popup lands on the spark's settled position.
	emit_signal("eaten", value, position)

func _advance_phase(delta):
	phase_left -= delta
	if phase_left <= 0.0:
		phase_index = (phase_index + 1) % PHASES.size()
		scattering = not scattering
		phase_left = PHASES[phase_index]

func _on_level_warped() -> void:
	position = target_position

func _on_area_2d_body_entered(body: Node2D) -> void:
	if not body.is_in_group('player'):
		return
	
	if state == State.FRIGHTENED:
		_get_eaten()
	elif state == State.HUNTING:
		# Penned in, leaving, or already eaten - harmless either way.
		emit_signal("lose")
		print('hit!')
		lost = true
