extends RefCounted

# Deliberately no class_name: this file is referenced by preload, so it works
# whether or not Godot's global class cache has been regenerated.

# Scores live under user:// so they survive the app closing. An autoload would
# not - it dies with the process, and a stand runs all day.
const PATH = "user://leaderboard.cfg"
const MAX_ENTRIES = 8


static func load_all() -> Array:
	var cfg = ConfigFile.new()
	if cfg.load(PATH) != OK:
		return [] # no file yet, or it's unreadable - start empty
	var entries = cfg.get_value("board", "entries", [])
	if typeof(entries) != TYPE_ARRAY:
		return []
	
	# Anything hand-edited or written by an older build gets dropped rather than
	# crashing the game-over screen in front of a queue.
	var clean := []
	for e in entries:
		if typeof(e) == TYPE_DICTIONARY and e.has("name") and e.has("score"):
			clean.append({
				"name": str(e["name"]).substr(0, 3),
				"score": int(e["score"]),
				"boards": int(e.get("boards", 0)),
			})
	return clean


static func save_all(entries: Array) -> void:
	var cfg = ConfigFile.new()
	cfg.set_value("board", "entries", entries)
	cfg.save(PATH)


static func qualifies(score: int) -> bool:
	if score <= 0:
		return false
	var entries = load_all()
	if entries.size() < MAX_ENTRIES:
		return true
	return score > int(entries[MAX_ENTRIES - 1]["score"])


# Returns the rank the entry landed at, or -1 if it didn't make the board.
static func insert(player_name: String, score: int, boards: int) -> int:
	var entries = load_all()
	var rank = entries.size()
	for i in range(entries.size()):
		if score > int(entries[i]["score"]):
			rank = i
			break
	
	entries.insert(rank, {"name": player_name, "score": score, "boards": boards})
	if entries.size() > MAX_ENTRIES:
		entries.resize(MAX_ENTRIES)
	save_all(entries)
	return rank if rank < MAX_ENTRIES else -1


static func clear() -> void:
	save_all([])
