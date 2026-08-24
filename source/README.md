# Cable Bug

Pac-Man style arcade game for use during the Cable Bug promotional campaign. To be deployed on the CK Tribe site & used as an attraction on trade show stands.

This document is meant to cover the parts I imagine would be of interest to IT. I can't imagine you'd care particularly how the game itself works - it's literally just Pac-Man. What does feel relevant is how we handle scores & the leaderboard.

Test build: https://carlkammerling-international.github.io/cablebug/

---

# File Structure

scenes/           
  title.tscn         entry point (set as main scene)
  level.tscn         the game itself
  gameover.tscn      score table, initial entry, prize-draw trigger
  cablebug.tscn      the player
  spark.tscn         one enemy, instanced four times with different behaviour
  pellet / power_pellet / item / lives

scripts/           gameplay code
  level.gd           round flow: READY beat, death, board clear, warps
  cablebug.gd        player movement (grid-locked, direction-buffered)
  spark.gd           enemy AI: four personalities, frightened and eaten states
  gameover.gd        leaderboard table, initial entry, prize-draw form
  title.gd           attract-free title screen

scripts/services/  persistent code (autoloads) and database-accessing scripts
  global.gd          autoload: score, lives, power-up state
  leaderboard.gd     local top-8 cache in user://
  remote_scores.gd   autoload: all network traffic lives here
  touch_input.gd     autoload: swipe-to-steer for touch devices

assets/
  sprites/  fonts/  audio/

web/
  shell.html         custom HTML shell: prize-draw form + mobile fullscreen

supabase/
  functions/score-api/   Edge Function - the only thing that can write scores
  schema/lockdown.sql    RLS policies and constraints

build/web/         exported web build (published to GitHub Pages)

---

## Networking - overview

The game connects to a free Supabase database to store high scores - the specific information being captured is a score, name (three characters long, in the style of an arcade game - not really worth considering sensitive information) and board count (how many levels the player cleared). A second table contains the above information & an email address - obtained via a prompt on the results screen, optionally. A link is provided to our privacy policy (same as C.K Tribe one). Since this *does* constitute sensitive information, more care has been taken to ensure this table isn't readable from the client side.

A third table, 'used_sessions', is used to track the usage of tokens issued by the server - more on this in a moment.

Only two files talk to anything outside the machine:

`scripts/services/remote_scores.gd` | reads the leaderboard, requests a session token, submits scores
`web/shell.html` | submits a prize-draw entry (name + email)

Everything else is local.

## Security model

The published build contains a Supabase anon key. Anyone can extract it, so
it is treated as public and has exactly one capability: reading the score
table. It cannot insert, update or delete in any table. The email addresses are stored in a separate table, which this key does not grant access to.

All writes go through the `score-api` Edge Function:

1. `level.gd` calls `{"action":"start"}` when a round begins. The function
   returns a session id, its issue time, and an HMAC over both. The signing
   secret (`SCORE_SIGNING_SECRET`) exists only in the function's environment.
2. At game over the client submits the score, or the HTML form submits a
   prize-draw entry, presenting that token.
3. The function verifies the signature, spends the token (one use per action,
   enforced by a primary key on `used_sessions`), checks the score is achievable
   in the elapsed time, then writes using the `service_role` key - which never
   leaves Supabase.

This function is set up to reject entries for the following reasons: forged signatures (401), implausible scores (400), replays (409). For the sake of being honest, it is still possible to forge a score if you're dedicated enough - you could in theory use your session token to push a high score to the server and, as long as it's technically possible (score isn't higher than is possible within the given board count, score isn't abitrarily high), it would be treated as valid. In all honesty, the reason this is the case is that I don't really know how to fix it without implementing a system that captures a replay of each input, and seeds the ghosts' movement etc. Making the game deterministic and validating the score against actual inputs would be the most secure way to avoid faked scores, but that feels out of scope to me.

### Data protection

`contest_entries` holds names and email addresses entered through the 'shell.html' prompt. Unlike the scores table, this table is set up to be append only - its data isn't readable from client side, and existing rows can't be edited by the client either. The key issued to the client by default is only set up to read the scoreboard - each session is given a single-use token that lets them write to the entries table, which is minted server-side and can't be generated by the user. This token is SHA-256 encrypted and each token submitted by a user is recomputed to reject any mismatches.

In short, what I'm getting at is that the section where we capture anything sensitive is locked down to ensure it can't be accessed by anyone else. The SCORE_SIGNING_SECRET key was generated on my end using the terminal command 'openssl rand -hex 32', resulting in a 32-character long random string.

## Building

Requires Godot 4.6 with the Web export template installed.

```
godot --headless --path . --export-release "Web" build/web/index.html
```

Then copy the contents of `build/web/` to the root of the Pages repo. `index.html`
must sit at the root, and `.nojekyll` must be present.

The export uses `web/shell.html` as a custom HTML shell; edits to the prize-draw
form or the fullscreen behaviour go there and only take effect after a re-export.
