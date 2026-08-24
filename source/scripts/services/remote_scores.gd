extends Node

# Online leaderboard (Supabase PostgREST).
#
# Nothing here is allowed to block the game. Every call is fire-and-forget with
# a short timeout; the local user:// board stays the source of truth for what's
# drawn on screen, and a successful fetch just refreshes that cache. Trade-show
# wi-fi is assumed to be bad or absent.

const Leaderboard = preload("res://scripts/services/leaderboard.gd")

const BASE_URL = "https://obzvqjwwmmrtoqjibpry.supabase.co"
const ANON_KEY = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Im9ienZxand3bW1ydG9xamlicHJ5Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODcyMzY5MzYsImV4cCI6MjEwMjgxMjkzNn0.VSNeGnd_BAY9qB_4mBIBibYUxozbSCGMSWxYkeudJ1c"
const TABLE = "scores"
# Writes go through the Edge Function, which holds the only credential that can
# touch the database. Reads still come straight from PostgREST - the anon key
# is allowed to read the leaderboard and nothing else.
const FUNCTION_URL = BASE_URL + "/functions/v1/score-api"
const TIMEOUT = 4.0
const QUEUE_PATH = "user://pending_scores.cfg"
const MAX_ATTEMPTS = 5

signal board_fetched(entries: Array)

var last_error = ""

# Signed, single-use, time-bounded. Issued when a round starts so the server can
# judge whether the score was achievable in the elapsed time.
var session = {}


func _ready() -> void:
	# Anything that failed to send on a previous run gets another go at boot.
	_flush_queue()


# Called when a round begins. Failure is not fatal: submission will just fail
# later and queue for retry.
func start_session() -> void:
	var req = _new_request()
	var body = JSON.stringify({"action": "start"})
	if req.request(FUNCTION_URL, _headers(), HTTPClient.METHOD_POST, body) != OK:
		req.queue_free()
		return
	
	var result = await req.request_completed
	req.queue_free()
	if int(result[1]) != 200:
		last_error = "session start failed (%s)" % result[1]
		return
	
	var parsed = JSON.parse_string((result[3] as PackedByteArray).get_string_from_utf8())
	if typeof(parsed) == TYPE_DICTIONARY and parsed.has("sig"):
		session = parsed
		last_error = ""


func has_session() -> bool:
	return session.has("sig")


func _headers() -> PackedStringArray:
	return PackedStringArray([
		"apikey: " + ANON_KEY,
		"Authorization: Bearer " + ANON_KEY,
		"Content-Type: application/json",
	])


func _new_request() -> HTTPRequest:
	var req = HTTPRequest.new()
	req.timeout = TIMEOUT
	# On the web the browser decompresses the response itself, but HTTPRequest
	# still sees Content-Encoding and tries to gunzip it a second time, which
	# corrupts the body and fails the JSON parse. The payloads here are a few
	# hundred bytes, so nothing is lost by asking for them uncompressed.
	req.accept_gzip = false
	add_child(req)
	return req


# --- reading ----------------------------------------------------------------

# Fetches the global top N and, on success, caches it as the local board so the
# screens have something to draw next time even with no network.
func refresh(limit: int = Leaderboard.MAX_ENTRIES) -> void:
	var url = "%s/rest/v1/%s?select=name,score,boards&order=score.desc&limit=%d" % [BASE_URL, TABLE, limit]
	var req = _new_request()
	if req.request(url, _headers(), HTTPClient.METHOD_GET) != OK:
		req.queue_free()
		last_error = "could not start request"
		return
	
	var result = await req.request_completed
	req.queue_free()
	
	var code = result[1]
	var body = (result[3] as PackedByteArray).get_string_from_utf8()
	if code != 200:
		last_error = "GET %d: %s" % [code, body]
		return
	
	var parsed = JSON.parse_string(body)
	if typeof(parsed) != TYPE_ARRAY:
		last_error = "GET returned something that isn't a list"
		return
	
	var entries := []
	for row in parsed:
		if typeof(row) == TYPE_DICTIONARY and row.has("name") and row.has("score"):
			entries.append({
				"name": str(row["name"]).substr(0, 3),
				"score": int(row["score"]),
				"boards": int(row.get("boards", 0)),
			})
	
	last_error = ""
	if not entries.is_empty():
		Leaderboard.save_all(entries) # cache the global board locally
	board_fetched.emit(entries)


# --- writing (via the Edge Function) ---------------------------------------

func submit(player_name: String, score: int, boards: int) -> void:
	var payload = {"name": player_name, "score": score, "boards": boards}
	
	# The server enforces this too, but catching it here means a malformed score
	# never burns the session token.
	if not _valid(payload):
		last_error = "refusing to send malformed score: " + JSON.stringify(payload)
		return
	
	# Retries must reuse the token the score was earned with, not a fresh one:
	# the server judges the score against the token's issue time, and a new
	# token would look like an impossibly fast game.
	var token = session.duplicate(true)
	if token.is_empty():
		# No token means the round never registered a start. The server can
		# never accept this, so queueing it would just be litter.
		last_error = "no session token - score cannot be submitted"
		return
	
	if _should_retry(await _post(payload, token)):
		payload["_attempts"] = 1
		payload["_token"] = token
		_queue(payload)


func _valid(payload: Dictionary) -> bool:
	return (str(payload.get("name", "")).length() == 3
		and int(payload.get("score", -1)) >= 0
		and int(payload.get("boards", -1)) >= 0)


# Returns the HTTP status, or 0 if the request never got off the ground.
func _post(payload: Dictionary, token: Dictionary) -> int:
	if token.is_empty():
		last_error = "no session token - the round never registered a start"
		return 0
	
	var req = _new_request()
	var body = {
		"action": "score",
		"token": token,
		"name": payload.get("name", ""),
		"score": int(payload.get("score", 0)),
		"boards": int(payload.get("boards", 0)),
	}
	if req.request(FUNCTION_URL, _headers(), HTTPClient.METHOD_POST, JSON.stringify(body)) != OK:
		req.queue_free()
		last_error = "could not start request"
		return 0
	
	var result = await req.request_completed
	req.queue_free()
	
	var code = int(result[1])
	if code == 200 or code == 201 or code == 204:
		last_error = ""
		return code
	last_error = "POST %d: %s" % [code, (result[3] as PackedByteArray).get_string_from_utf8()]
	return code


# Only re-send failures that might clear up. A 400 means the server rejected the
# payload on its own terms and a 409 means the token is spent - neither will ever
# succeed, so queueing them would mean retrying something doomed on every launch.
func _should_retry(code: int) -> bool:
	if code == 400 or code == 409:
		return false
	return code == 0 or code >= 500 or code == 401 or code == 403


# --- offline queue ----------------------------------------------------------

func _queue(payload: Dictionary) -> void:
	var pending = _load_queue()
	pending.append(payload)
	if pending.size() > 50:
		pending = pending.slice(pending.size() - 50, pending.size())
	var cfg = ConfigFile.new()
	cfg.set_value("queue", "pending", pending)
	cfg.save(QUEUE_PATH)


func _load_queue() -> Array:
	var cfg = ConfigFile.new()
	if cfg.load(QUEUE_PATH) != OK:
		return []
	var pending = cfg.get_value("queue", "pending", [])
	return pending if typeof(pending) == TYPE_ARRAY else []


func _flush_queue() -> void:
	var pending = _load_queue()
	if pending.is_empty():
		return
	
	var still_failing := []
	for entry in pending:
		if typeof(entry) != TYPE_DICTIONARY:
			continue
		
		var payload = {
			"name": str(entry.get("name", "")),
			"score": int(entry.get("score", 0)),
			"boards": int(entry.get("boards", 0)),
		}
		var token = entry.get("_token", {})
		if not _valid(payload) or typeof(token) != TYPE_DICTIONARY or token.is_empty():
			continue # junk, or earned before tokens existed - drop it
		
		if _should_retry(await _post(payload, token)):
			# Hard cap, so nothing can rattle away at the server indefinitely
			# however it is failing.
			var attempts = int(entry.get("_attempts", 0)) + 1
			if attempts < MAX_ATTEMPTS:
				payload["_attempts"] = attempts
				payload["_token"] = token
				still_failing.append(payload)
	
	var cfg = ConfigFile.new()
	cfg.set_value("queue", "pending", still_failing)
	cfg.save(QUEUE_PATH)


func pending_count() -> int:
	return _load_queue().size()
