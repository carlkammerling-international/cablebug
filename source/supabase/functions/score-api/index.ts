// Score / prize-draw write gateway.
//
// The browser has no write access to the database. It holds only the anon key,
// which after setup.sql can read the leaderboard and nothing else. Every write
// goes through here, using the service_role key that never leaves the server.
//
// Flow:
//   1. the game calls {action:"start"} when a round begins and gets back an
//      opaque token: a session id, its issue time, and an HMAC over both;
//   2. at game over it calls {action:"score"} / {action:"entry"} with that
//      token. We recheck the signature, spend the token once per action, and
//      reject scores that could not have been achieved in the elapsed time.
//
// A signature cannot be minted client-side because SCORE_SIGNING_SECRET only
// exists in the function's environment.

import { createClient } from "https://esm.sh/@supabase/supabase-js@2.45.4";

// Read without "!" so a missing value is a clear message rather than a blind
// 500 from somewhere deep in a crypto or client call.
const SECRET = Deno.env.get("SCORE_SIGNING_SECRET") ?? "";
const SUPABASE_URL = Deno.env.get("SUPABASE_URL") ?? "";
const SERVICE_ROLE = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";

function missingConfig(): string[] {
  const missing: string[] = [];
  if (!SECRET) missing.push("SCORE_SIGNING_SECRET");
  if (!SUPABASE_URL) missing.push("SUPABASE_URL");
  if (!SERVICE_ROLE) missing.push("SUPABASE_SERVICE_ROLE_KEY");
  return missing;
}

// Game-derived limits. One board is worth at most 16,910 (2,710 pellets +
// 200 power pellets + 12,000 sparks + 1,000 fruit + 1,000 clear bonus).
const MAX_PER_BOARD = 17000;
const MAX_BOARDS = 20;
// Deliberately generous. The elapsed-time test is a *minimum* - it rejects
// scores achieved impossibly fast - so a long window does not weaken it, and it
// lets a submission queued while offline still land on the next launch.
const TOKEN_TTL_MS = 24 * 60 * 60 * 1000;
const MIN_MS_PER_BOARD = 60_000; // a board cannot be cleared inside a minute
const MIN_MS_FOR_ANY_REAL_SCORE = 5_000;

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

// Built lazily: constructing this at module scope with an empty URL throws
// during import, which surfaces as an opaque 500 on every single request.
let _admin: ReturnType<typeof createClient> | null = null;
function db() {
  if (!_admin) {
    _admin = createClient(SUPABASE_URL, SERVICE_ROLE, { auth: { persistSession: false } });
  }
  return _admin;
}

function reply(status: number, body: Record<string, unknown>) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...CORS, "Content-Type": "application/json" },
  });
}

async function hmac(message: string): Promise<string> {
  const key = await crypto.subtle.importKey(
    "raw",
    new TextEncoder().encode(SECRET),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const sig = await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(message));
  return [...new Uint8Array(sig)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

// Length-independent compare, so a timing signal can't leak the signature.
function sameSignature(a: string, b: string): boolean {
  if (typeof a !== "string" || typeof b !== "string" || a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return diff === 0;
}

type Token = { sid: string; iat: number; sig: string };

async function checkToken(t: Token): Promise<{ ok: true; elapsed: number } | { ok: false; why: string }> {
  if (!t || typeof t.sid !== "string" || typeof t.iat !== "number" || typeof t.sig !== "string") {
    return { ok: false, why: "malformed token" };
  }
  const expected = await hmac(`${t.sid}.${t.iat}`);
  if (!sameSignature(expected, t.sig)) return { ok: false, why: "bad signature" };

  const elapsed = Date.now() - t.iat;
  if (elapsed < 0) return { ok: false, why: "token issued in the future" };
  if (elapsed > TOKEN_TTL_MS) return { ok: false, why: "token expired" };
  return { ok: true, elapsed };
}

// Spending a token is an insert against a primary key, so two racing requests
// cannot both win - the second gets a duplicate-key error.
async function spend(sid: string, action: string): Promise<boolean> {
  const { error } = await db().from("used_sessions").insert({ sid, action });
  return !error;
}

function scoreIsPossible(score: number, boards: number, elapsed: number): string | null {
  if (!Number.isInteger(score) || !Number.isInteger(boards)) return "score and boards must be integers";
  if (score < 0 || boards < 0) return "negative values";
  if (boards > MAX_BOARDS) return "board count beyond anything achievable";
  if (score > (boards + 1) * MAX_PER_BOARD) return "score too high for the boards cleared";
  if (boards > 0 && elapsed < boards * MIN_MS_PER_BOARD) return "boards cleared too quickly";
  if (score > 1000 && elapsed < MIN_MS_FOR_ANY_REAL_SCORE) return "scored too quickly";
  return null;
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.method !== "POST") return reply(405, { error: "POST only" });

  let body: Record<string, any>;
  try {
    body = await req.json();
  } catch {
    return reply(400, { error: "invalid JSON" });
  }

  // Says what is wrong without revealing any value.
  if (body.action === "health") {
    const missing = missingConfig();
    let sessionsTable = "unknown";
    if (missing.length === 0) {
      const { error } = await db().from("used_sessions").select("sid").limit(1);
      sessionsTable = error ? "MISSING: " + error.message : "ok";
    }
    return reply(200, { missing_env: missing, used_sessions: sessionsTable });
  }

  const missing = missingConfig();
  if (missing.length > 0) {
    return reply(500, { error: "function is not configured", missing_env: missing });
  }

  // --- issue a token -------------------------------------------------------
  if (body.action === "start") {
    const sid = crypto.randomUUID();
    const iat = Date.now();
    return reply(200, { sid, iat, sig: await hmac(`${sid}.${iat}`) });
  }

  // --- everything else needs a valid, unspent token -------------------------
  const check = await checkToken(body.token);
  if (!check.ok) return reply(401, { error: check.why });
  const { elapsed } = check;

  if (body.action === "score") {
    const name = String(body.name ?? "").toUpperCase();
    const score = Number(body.score);
    const boards = Number(body.boards);

    if (!/^[A-Z]{3}$/.test(name)) return reply(400, { error: "initials must be three letters" });
    const bad = scoreIsPossible(score, boards, elapsed);
    if (bad) return reply(400, { error: bad });

    if (!(await spend(body.token.sid, "score"))) return reply(409, { error: "token already used" });

    const { error } = await db().from("scores").insert({ name, score, boards });
    if (error) return reply(500, { error: "insert failed", detail: error.message });
    return reply(201, { ok: true });
  }

  if (body.action === "entry") {
    const fullName = String(body.full_name ?? "").trim();
    const email = String(body.email ?? "").trim();
    const initials = String(body.initials ?? "").toUpperCase();
    const score = Number(body.score);
    const boards = Number(body.boards);

    if (fullName.length < 1 || fullName.length > 80) return reply(400, { error: "name length" });
    if (email.length > 120 || !/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(email)) return reply(400, { error: "invalid email" });
    if (!/^[A-Z]{3}$/.test(initials)) return reply(400, { error: "initials must be three letters" });
    const bad = scoreIsPossible(score, boards, elapsed);
    if (bad) return reply(400, { error: bad });

    if (!(await spend(body.token.sid, "entry"))) return reply(409, { error: "token already used" });

    const { error } = await db().from("contest_entries").insert({
      initials, full_name: fullName, email, score, boards,
    });
    if (error) return reply(500, { error: "insert failed", detail: error.message });
    return reply(201, { ok: true });
  }

  return reply(400, { error: "unknown action" });
});
