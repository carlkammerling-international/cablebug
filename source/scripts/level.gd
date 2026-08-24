extends Node2D
signal game_start
const BOARD_BONUS = 1000 # paid for clearing every pellet on the board
const EAT_FREEZE = 0.35 # hit-stop when a spark is caught
const READY_TIME = 1.5 # stillness before a life starts, so the player can orient
const POPUP_FONT = preload("res://assets/fonts/C&C Red Alert [INET].ttf")
const POWER_TIME = 10.0 # generous: a trade-show frenzy should feel like a reward
var losing = false
var clearing = false
var freeze_token = 0
var power_token = 0

const Leaderboard = preload("res://scripts/services/leaderboard.gd")


func _ready() -> void:
	# global is an autoload, so it survives reload_current_scene(). Dying mid
	# power pellet used to leave power_up stuck on forever, which left every
	# spark permanently blue.
	global.power_up = false
	global.power_combo = 0
	_dismiss_stale_overlay()
	# Ask for a session token now, so the server can judge the final score
	# against how long the round actually took.
	if not remote_scores.has_session():
		remote_scores.start_session()
	emit_signal("game_start")
	await _ready_beat()
	_show_best()

func _show_best() -> void:
	var entries = Leaderboard.load_all()
	if entries.is_empty():
		$score2.text = ""
	else:
		$score2.text = "%s   %d" % [entries[0]["name"], int(entries[0]["score"])]

# The prize-draw form is DOM, not a Godot node, so it outlives scene changes. If
# one is ever left open - a half-finished submit, or someone poking at the page -
# it would float over the maze. Starting a game clears it.
func _dismiss_stale_overlay() -> void:
	if OS.has_feature("web"):
		JavaScriptBridge.eval("if (window.CKContest && window.CKContest.state === 'open') { window.CKContest.close('stale'); }", true)


# Left Warp Tunnel (Moves things to the right side of the screen)
func _on_warp_entered(body: Node2D) -> void:
	if body.is_in_group("enemy1") and not body.just_warped:
		body.just_warped = true
		
		# 1. Teleport the character
		body.position.x += 240
		body.target_position.x += 240
		
		# 3. Small delay before allowing new turns
		await get_tree().create_timer(0.1).timeout
		body.just_warped = false
	
	if body.is_in_group("player") and not body.just_warped:
		body.teleport_to_right(Vector2(240,0))


# Right Warp Tunnel (Moves things to the left side of the screen)
func _on_warp_right(body: Node2D) -> void:
	if body.is_in_group("enemy1") and not body.just_warped:
		body.just_warped = true
		body.is_warping = true
		
		body.position.x -= 240
		body.target_position.x -= 240
		
		await get_tree().create_timer(0.1).timeout
		body.is_warping = false
		body.just_warped = false
	
	if body.is_in_group("player") and not body.just_warped:
		body.teleport_to_left(Vector2(240,0))

func _on_lose() -> void:
	if losing:
		return # Four sparks can touch the player on the same frame.
	losing = true
	$death_sound.play()
	
	# Arcade behaviour: the sparks clear off so the death animation plays alone,
	# instead of milling around on top of the body.
	for spark in get_tree().get_nodes_in_group("enemy1"):
		spark.lost = true
		spark.visible = false
	
	$bug/AnimatedSprite2D.play('die')
	await get_tree().create_timer(2.0).timeout
	$bug.visible = false # kept alive - the next life reuses it
	await get_tree().create_timer(1.0).timeout
	global.lives -= 1
	if global.lives > 0:
		await _reset_round()
	else:
		get_tree().change_scene_to_file("res://scenes/gameover.tscn")


# Reset the actors only. reload_current_scene() would bring back every pellet
# the player had already cleared, so a board could only ever be finished on a
# single life.
func _reset_round() -> void:
	global.power_up = false
	global.power_combo = 0
	$bug.reset_to_spawn()
	for spark in get_tree().get_nodes_in_group("enemy1"):
		spark.reset_to_spawn()
	await _ready_beat()
	losing = false


# Hold everything still with READY! up. Without this the player reappears with
# Blinky already bearing down and no moment to get their bearings.
func _ready_beat() -> void:
	$bug.lost = true
	for spark in get_tree().get_nodes_in_group("enemy1"):
		spark.lost = true
	$ready_label.visible = true
	
	# The beat is driven by a SceneTreeTimer rather than by polling
	# AudioStreamPlayer.playing. Same duration either way, but this doesn't make
	# gameplay progression depend on the audio subsystem reaching the end of a
	# stream - which is a thing browsers can be funny about.
	var beat = READY_TIME
	if $ready_jingle.stream:
		beat = clampf($ready_jingle.stream.get_length(), READY_TIME, 6.0)
	$ready_jingle.play()
	await get_tree().create_timer(beat).timeout
	
	$ready_label.visible = false
	$bug.lost = false
	for spark in get_tree().get_nodes_in_group("enemy1"):
		spark.lost = false

func _on_powerup() -> void:
	global.power_up = true
	global.power_combo = 0
	global.power_cycle += 1
	global.power_up_until = Time.get_ticks_msec() / 1000.0 + POWER_TIME
	
	# Token guard: grabbing a second power pellet mid-frenzy must extend it, not
	# let the first pellet's timer cut the new one short.
	power_token += 1
	var my_token = power_token
	await get_tree().create_timer(POWER_TIME, false).timeout
	if my_token == power_token:
		global.power_up = false


# Hit-stop. A beat of dead air so catching a spark lands as an event, instead
# of the eyes just gliding away mid-stride.
func _on_spark_eaten(value: int, at: Vector2) -> void:
	freeze_token += 1
	var my_token = freeze_token
	
	$eat_sound.play()
	var popup = _score_popup(value, at)
	
	# The frenzy clock pauses along with the tree, so push out the wall-clock
	# deadline the sparks flash against by the same amount.
	global.power_up_until += EAT_FREEZE
	
	get_tree().paused = true
	# process_always, so this timer still runs while the tree is paused.
	await get_tree().create_timer(EAT_FREEZE, true).timeout
	
	if is_instance_valid(popup):
		popup.queue_free()
	
	# Only the most recent freeze may lift the pause - eating two sparks in
	# quick succession must not cut the second one short.
	if my_token == freeze_token:
		get_tree().paused = false


# The value floating over the spark you just caught. Fills the hit-stop, and
# teaches the 200/400/800/1600 ladder without a word of explanation.
# The fruit is the biggest single pickup in the game (up to 1000) and used to
# land in silence. No hit-stop here - it just floats for a moment.
func _on_item_picked_up(value: int, at: Vector2) -> void:
	var popup = _score_popup(value, at, Color(1, 0.85, 0.3))
	await get_tree().create_timer(1.0).timeout
	if is_instance_valid(popup):
		popup.queue_free()


func _score_popup(value: int, at: Vector2, tint := Color(0.6, 1, 1)) -> Label:
	var label = Label.new()
	label.text = str(value)
	
	var settings = LabelSettings.new()
	settings.font = POPUP_FONT
	settings.font_size = 10
	settings.font_color = tint
	label.label_settings = settings
	
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.z_index = 10
	label.process_mode = Node.PROCESS_MODE_ALWAYS # must survive the hit-stop
	add_child(label)
	label.size = Vector2(40, 16)
	label.position = at - Vector2(20, 8)
	return label


func _on_pellets_win() -> void:
	if clearing:
		return
	clearing = true
	
	global.boards_cleared += 1
	global.score += BOARD_BONUS
	
	# Hold everything still for a beat so the clear actually registers, rather
	# than the board blinking back to full mid-stride.
	$bug.lost = true
	for spark in get_tree().get_nodes_in_group("enemy1"):
		spark.lost = true
		spark.visible = false
	await get_tree().create_timer(2.0).timeout
	
	$pellets.respawn_all()
	for pp in get_tree().get_nodes_in_group("power_pellet"):
		pp.respawn()
	for it in get_tree().get_nodes_in_group("board_item"):
		it.respawn()
	
	# Same actor reset a death uses - score and lives carry over untouched.
	await _reset_round()
	clearing = false
