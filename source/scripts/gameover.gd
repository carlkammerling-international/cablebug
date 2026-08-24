extends Node2D

# An unattended stand must never get stuck, so every state times out on its own.
const RESTART_AFTER = 12.0 # showing the table
const ENTRY_TIMEOUT = 30.0 # someone walked off mid-entry
const LETTERS = "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
const ROW_FONT = preload("res://assets/fonts/C&C Red Alert [INET].ttf")
const Leaderboard = preload("res://scripts/services/leaderboard.gd")

# Link shown next to the consent tick. Leave blank and no link is drawn.
const PRIVACY_URL = "https://www.ck-tribe.com/privacy-policy"

var entering = false
var slot = 0
var picks = [0, 0, 0]
var time_left = RESTART_AFTER
var restarting = false
var blink = 0.0
var placed_name = ""
var placed_score = -1
var contest_open = false


func _ready() -> void:
	$final.text = "SCORE  %d" % global.score
	
	# The signal connection dies with this node, so a slow reply landing after
	# the screen has gone can't touch a freed scene.
	remote_scores.board_fetched.connect(_on_board_fetched)
	remote_scores.refresh()
	
	for i in range(3):
		$entry/touch_ui.get_node("up%d" % i).pressed.connect(_on_slot_step.bind(i, -1))
		$entry/touch_ui.get_node("dn%d" % i).pressed.connect(_on_slot_step.bind(i, 1))
	$entry/touch_ui/done.pressed.connect(_on_entry_done)
	if Leaderboard.qualifies(global.score):
		_begin_entry()
	else:
		_show_table(-1)


func _process(delta: float) -> void:
	# While the HTML form is up the player is typing, so the auto-restart must
	# not fire underneath them and throw the game back to the title.
	if contest_open:
		if str(JavaScriptBridge.eval("window.CKContest ? window.CKContest.state : 'closed'", true)) == "open":
			return
		contest_open = false
		time_left = RESTART_AFTER # give them a fresh read of the table
	
	time_left -= delta
	
	if entering:
		blink += delta
		_handle_entry_gestures()
		_paint_slots()
		$hint.text = "ENTER TO CONFIRM   %d" % ceili(max(time_left, 0.0))
		if time_left <= 0.0:
			_submit() # walked away - take what's on screen rather than hanging
	else:
		$hint.text = "PRESS ANY KEY   %d" % ceili(max(time_left, 0.0))
		if time_left <= 0.0:
			_restart()


# --- initial entry ----------------------------------------------------------

func _begin_entry() -> void:
	entering = true
	time_left = ENTRY_TIMEOUT
	$entry.visible = true
	$leaderboard.visible = false
	_setup_touch_entry()
	_paint_slots()


# Gestures work, but nothing on screen says so. On a touch device the slots get
# spread out into proper tap targets with visible arrows and a DONE button;
# on desktop the compact keyboard layout is left alone.
func _setup_touch_entry() -> void:
	var touch = DisplayServer.is_touchscreen_available()
	$entry/touch_ui.visible = touch
	if not touch:
		return
	
	# Neither font has a triangle glyph, and "^" / "v" read as punctuation
	# rather than arrows. Drawn as pixel triangles instead, which sit better
	# with the rest of the art.
	var up_icon = _triangle_icon(13, 7, true)
	var down_icon = _triangle_icon(13, 7, false)
	for i in range(3):
		_as_arrow($entry/touch_ui.get_node("up%d" % i), up_icon)
		_as_arrow($entry/touch_ui.get_node("dn%d" % i), down_icon)
	
	var centres = [96.0, 160.0, 224.0]
	for i in range(3):
		var label = _slot_label(i)
		label.offset_left = centres[i] - 22.0
		label.offset_right = centres[i] + 22.0
		label.offset_top = 118.0
		label.offset_bottom = 152.0
	$entry/entry_help.text = "TAP THE ARROWS"


func _as_arrow(button: Button, icon: Texture2D) -> void:
	button.text = ""
	button.icon = icon
	button.expand_icon = false
	button.add_theme_color_override("icon_normal_color", Color(1, 0.85, 0.1))
	button.add_theme_color_override("icon_pressed_color", Color(1, 1, 1))
	button.add_theme_color_override("icon_hover_color", Color(1, 1, 1))


# A solid triangle, one pixel wider each row from the apex. White, so the
# button's icon colour overrides do the tinting.
func _triangle_icon(width: int, height: int, pointing_up: bool) -> ImageTexture:
	var img = Image.create(width, height, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))
	var centre = width / 2
	for y in range(height):
		var row = y if pointing_up else height - 1 - y
		for x in range(maxi(centre - row, 0), mini(centre + row + 1, width)):
			img.set_pixel(x, y, Color.WHITE)
	return ImageTexture.create_from_image(img)


func _on_slot_step(index: int, step: int) -> void:
	if not entering:
		return
	slot = index
	picks[index] = (picks[index] + step + LETTERS.length()) % LETTERS.length()
	time_left = ENTRY_TIMEOUT
	_paint_slots()


func _on_entry_done() -> void:
	if entering:
		_submit()


func _slot_label(i: int) -> Label:
	return $entry.get_node("char%d" % i)


func _paint_slots() -> void:
	for i in range(3):
		var label = _slot_label(i)
		label.text = LETTERS[picks[i]]
		if i == slot:
			# blink the slot being edited so it's obvious where you are
			label.modulate = Color(1, 0.85, 0.1) if fmod(blink, 0.6) < 0.35 else Color(0.4, 0.3, 0.0)
		else:
			label.modulate = Color(1, 1, 1)


func _entry_input(event: InputEvent) -> void:
	# Letters are checked BEFORE the movement actions on purpose: W/A/S/D are
	# bound to movement, and on this screen typing your initials has to win.
	if event is InputEventKey and event.keycode >= KEY_A and event.keycode <= KEY_Z:
		picks[slot] = event.keycode - KEY_A
		if slot < 2:
			slot += 1
		_paint_slots()
		return
	
	# ui_accept has no pad binding, so a controller could scroll the letters but
	# never commit them. Handle the face button explicitly.
	if event is InputEventJoypadButton and event.pressed and event.button_index == JOY_BUTTON_A:
		if slot < 2:
			slot += 1
			_paint_slots()
		else:
			_submit()
		return
	
	if event.is_action_pressed("moveup"):
		picks[slot] = (picks[slot] - 1 + LETTERS.length()) % LETTERS.length()
	elif event.is_action_pressed("movedown"):
		picks[slot] = (picks[slot] + 1) % LETTERS.length()
	elif event.is_action_pressed("moveleft"):
		slot = max(slot - 1, 0)
	elif event.is_action_pressed("moveright"):
		slot = min(slot + 1, 2)
	elif event.is_action_pressed("ui_accept"):
		if slot < 2:
			slot += 1
		else:
			_submit()
			return
	else:
		return
	_paint_slots()


# On a phone there is no keyboard and no pad, so the three slots are driven by
# gesture: swipe up/down to change the letter, left/right to move between slots,
# tap to confirm. Without this a mobile player can only wait for the timeout and
# take AAA.
func _handle_entry_gestures() -> void:
	var swipe = touch_input.take_direction()
	if swipe == Vector2.UP:
		picks[slot] = (picks[slot] - 1 + LETTERS.length()) % LETTERS.length()
		time_left = ENTRY_TIMEOUT
	elif swipe == Vector2.DOWN:
		picks[slot] = (picks[slot] + 1) % LETTERS.length()
		time_left = ENTRY_TIMEOUT
	elif swipe == Vector2.LEFT:
		slot = maxi(slot - 1, 0)
		time_left = ENTRY_TIMEOUT
	elif swipe == Vector2.RIGHT:
		slot = mini(slot + 1, 2)
		time_left = ENTRY_TIMEOUT
	
	# The gesture layer sees taps before the buttons do, so consume the tap
	# either way but only act on it when there are no buttons on screen.
	var tapped = touch_input.take_tap()
	if tapped and not $entry/touch_ui.visible:
		time_left = ENTRY_TIMEOUT
		if slot < 2:
			slot += 1
		else:
			_submit()


func _submit() -> void:
	if not entering:
		return
	entering = false
	var initials = ""
	for p in picks:
		initials += LETTERS[p]
	var rank = Leaderboard.insert(initials, global.score, global.boards_cleared)
	placed_name = initials
	placed_score = global.score
	
	_announce_place(rank)
	_show_table(rank)
	_submit_then_refresh(initials, global.score, global.boards_cleared)


# The refresh has to wait for the POST to resolve. Firing both together let the
# GET overtake the insert and return a board generated moments before the score
# existed - which then overwrote the local cache and wiped the player off their
# own leaderboard.
func _submit_then_refresh(initials: String, score: int, boards: int) -> void:
	await remote_scores.submit(initials, score, boards)
	remote_scores.refresh()


# --- the table --------------------------------------------------------------

func _show_table(highlight: int) -> void:
	entering = false
	time_left = RESTART_AFTER
	$entry.visible = false
	$leaderboard.visible = true
	_populate_leaderboard(highlight)
	_open_contest_form()


func _populate_leaderboard(highlight: int) -> void:
	for child in $leaderboard.get_children():
		child.queue_free()
	
	var entries = Leaderboard.load_all()
	if entries.is_empty():
		$leaderboard.add_child(_cell("NO SCORES YET", 180, HORIZONTAL_ALIGNMENT_CENTER, Color(0.6, 0.6, 0.6)))
		return
	
	# Capped here as well as at both write paths. The container expands rather
	# than clipping, so a longer cache would push rows into the hint text.
	for i in range(mini(entries.size(), Leaderboard.MAX_ENTRIES)):
		var tint = Color(1, 0.85, 0.1) if i == highlight else Color(1, 1, 1)
		var row = HBoxContainer.new()
		row.add_child(_cell("%d" % (i + 1), 20, HORIZONTAL_ALIGNMENT_RIGHT, tint))
		row.add_child(_cell(str(entries[i]["name"]), 60, HORIZONTAL_ALIGNMENT_CENTER, tint))
		row.add_child(_cell("%d" % int(entries[i]["score"]), 96, HORIZONTAL_ALIGNMENT_RIGHT, tint))
		$leaderboard.add_child(row)


# Fixed-width cells, because the font isn't monospaced and ragged columns look
# like a bug rather than a scoreboard.
func _cell(text: String, width: float, align: int, tint: Color) -> Label:
	var label = Label.new()
	label.text = text
	var settings = LabelSettings.new()
	settings.font = ROW_FONT
	settings.font_size = 11
	label.label_settings = settings
	label.horizontal_alignment = align
	label.custom_minimum_size = Vector2(width, 12)
	label.modulate = tint
	return label


func _on_board_fetched(entries: Array) -> void:
	# Only redraw if the table is what's on screen; never interrupt name entry.
	if entering or restarting or entries.is_empty():
		return
	
	# The rank shown at submit time was against the local cache. Now the global
	# board has landed, work out where they actually came and correct it.
	var board = entries.duplicate()
	var rank = _rank_in(board, placed_name, placed_score)
	
	if rank < 0 and placed_name != "" and placed_score >= 0:
		# Their score isn't in the global board - still queued offline, or this
		# response predates the insert. Merge it back; being shown a board you
		# have just topped, without yourself on it, is worse than being slightly
		# out of date.
		board.append({"name": placed_name, "score": placed_score, "boards": global.boards_cleared})
		board.sort_custom(func(a, b): return int(a["score"]) > int(b["score"]))
		if board.size() > Leaderboard.MAX_ENTRIES:
			board.resize(Leaderboard.MAX_ENTRIES)
		Leaderboard.save_all(board)
		rank = _rank_in(board, placed_name, placed_score)
	
	_announce_place(rank)
	_populate_leaderboard(rank)


func _rank_in(board: Array, who: String, score: int) -> int:
	for i in range(board.size()):
		if str(board[i].get("name", "")) == who and int(board[i].get("score", -1)) == score:
			return i
	return -1


# Someone who has just made the board would rather read where they came than
# the words GAME OVER.
func _announce_place(rank: int) -> void:
	# Self-correcting: if the global board turns out not to include them after
	# all, stop claiming a placing that isn't real.
	if rank < 0:
		$title.text = "GAME OVER"
		return
	$title.text = "%s PLACE" % _ordinal(rank + 1)


func _ordinal(n: int) -> String:
	var suffix = "TH"
	if n % 100 < 11 or n % 100 > 13:
		match n % 10:
			1: suffix = "ST"
			2: suffix = "ND"
			3: suffix = "RD"
	return "%d%s" % [n, suffix]


# The prize-draw form is plain HTML sitting over the canvas: it gets the real
# mobile keyboard, autofill and validation, none of which an in-engine text
# field would. Web only - the desktop build has a real keyboard anyway.
func _open_contest_form() -> void:
	if contest_open or global.score <= 0:
		return
	if not OS.has_feature("web"):
		return
	if not bool(JavaScriptBridge.eval("typeof window.CKContest !== 'undefined'", true)):
		return # running under a shell without the overlay
	
	var cfg = JSON.stringify({
		"url": remote_scores.FUNCTION_URL,
		"key": remote_scores.ANON_KEY,
		"token": remote_scores.session,
		"initials": placed_name if placed_name != "" else "---",
		"score": global.score,
		"boards": global.boards_cleared,
		"privacy_url": PRIVACY_URL,
	})
	JavaScriptBridge.eval("window.CKContest.show(%s)" % JSON.stringify(cfg), true)
	contest_open = true


# --- input / restart --------------------------------------------------------

func _unhandled_input(event: InputEvent) -> void:
	if restarting or contest_open:
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
	if not pressed:
		return
	
	if entering:
		if event is InputEventScreenTouch:
			return # taps and swipes are handled in _handle_entry_gestures
		time_left = ENTRY_TIMEOUT # still here, so keep waiting
		_entry_input(event)
	else:
		_restart()


func _restart() -> void:
	if restarting:
		return
	restarting = true
	set_process(false)
	
	# The globals are an autoload, so they outlive the scene - clear them here or
	# the next player inherits the last one's score, lives and board count.
	global.score = 0
	global.lives = 3
	global.power_up = false
	global.power_combo = 0
	global.boards_cleared = 0
	# Back to the title rather than straight into play: it shows the game's
	# name to whoever is walking past.
	get_tree().change_scene_to_file("res://scenes/title.tscn")
