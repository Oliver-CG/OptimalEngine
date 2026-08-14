#!/usr/bin/env bash
# Promote-toets v2 — the pre-registered governance gate for this fork.
#
# v1 (2026-08-14, _briefs/POC-optimal-engine.md in the HiggiHQ repo) measured
# the shipped engine: promotion without any approval field returned 200 and a
# confidence-0.55 claim became a "verified" fact signed "anonymous". This
# script re-runs those checks against a REPAIRED build with auth enabled, plus
# the guarantees the repairs added. It must stay green on every release; a
# red run blocks client data, full stop.
#
# Requirements: curl, jq. Keys come from test/acceptance/mint_toets_keys.exs.
#
#   OE_URL          engine base url          (default http://127.0.0.1:4200)
#   OE_KEY_ADMIN    scopes ["admin"]         (workspace setup/teardown)
#   OE_KEY_SERVICE  authenticated, geen principal
#   OE_KEY_REVIEWER principal user:toets-reviewer
#   OE_KEY_BRIDGE   principal system:memory-create-bridge
#
# Output: TAP-achtig, exit 0 alleen als ALLES slaagt.

set -u

OE_URL="${OE_URL:-http://127.0.0.1:4200}"
: "${OE_KEY_ADMIN:?zet OE_KEY_ADMIN}"
: "${OE_KEY_SERVICE:?zet OE_KEY_SERVICE}"
: "${OE_KEY_REVIEWER:?zet OE_KEY_REVIEWER}"
: "${OE_KEY_BRIDGE:?zet OE_KEY_BRIDGE}"

BODYFILE="$(mktemp)"
trap 'rm -f "$BODYFILE"' EXIT

PASS=0; FAIL=0; N=0
ok()  { N=$((N+1)); PASS=$((PASS+1)); printf 'ok %d - %s\n' "$N" "$1"; }
nok() { N=$((N+1)); FAIL=$((FAIL+1)); printf 'not ok %d - %s\n' "$N" "$1"; }
check() { # naam verwacht werkelijk
  if [ "$2" = "$3" ]; then ok "$1"; else nok "$1 (verwacht $2, kreeg $3) :: $(cat "$BODYFILE")"; fi
}

req() { # method path key [json] -> echoot statuscode; body in $BODYFILE
  local m=$1 p=$2 key=$3 data=${4:-}
  local args=(-sS -o "$BODYFILE" -w '%{http_code}' -X "$m" "$OE_URL$p" -H 'content-type: application/json')
  [ -n "$key" ] && args+=(-H "x-api-key: $key")
  [ -n "$data" ] && args+=(--data "$data")
  curl "${args[@]}" 2>/dev/null || printf '000'
}

SLUG="toets-$(date +%s)-$$"
printf '# promote-toets v2 — %s — workspace-slug %s\n' "$OE_URL" "$SLUG"

# ── A0 · zonder sleutel is de deur dicht ────────────────────────────────────
s=$(req GET /api/stats "")
check "A0 dataroute zonder sleutel -> 401" 401 "$s"

# ── H · health blijft sleutelloos (container-HEALTHCHECK is een kale wget) ──
s=$(req GET /api/health "")
check "H health zonder sleutel -> 200" 200 "$s"

# ── Setup · workspace + één claim via de memory-brug ────────────────────────
s=$(req POST /api/workspaces "$OE_KEY_ADMIN" "{\"slug\":\"$SLUG\",\"name\":\"Promote-toets $SLUG\"}")
WS=$(jq -r '.id // empty' "$BODYFILE")
if [ "$s" = "201" ] && [ -n "$WS" ]; then ok "setup workspace ($WS)"; else nok "setup workspace ($s) :: $(cat "$BODYFILE")"; fi

s=$(req POST /api/memory "$OE_KEY_REVIEWER" "{\"content\":\"De keukenproductiviteit was 71 euro per uur ($SLUG).\",\"workspace\":\"$WS\"}")
check "setup memory -> pending claim" 201 "$s"

s=$(req GET "/api/memory-core/claim-review?workspace=$WS" "$OE_KEY_SERVICE")
CLAIM=$(jq -r '.claims[0].id // empty' "$BODYFILE")
if [ -n "$CLAIM" ]; then ok "setup claim gevonden"; else nok "setup claim gevonden ($s) :: $(cat "$BODYFILE")"; fi

# ── A · promotie zonder goedkeurende principal — body-identiteit telt niet ──
s=$(req POST "/api/memory-core/claims/$CLAIM/promote" "$OE_KEY_SERVICE" "{\"workspace\":\"$WS\",\"actor_id\":\"user:aanvaller\",\"verifier_id\":\"user:aanvaller\"}")
check "A promotie zonder principal, body-asserted naam -> 403" 403 "$s"

# ── E · body-asserted vertrouwen/status koopt geen promotie ─────────────────
s=$(req POST "/api/memory-core/claims/$CLAIM/promote" "$OE_KEY_SERVICE" "{\"workspace\":\"$WS\",\"verification_status\":\"verified\",\"aggregate_confidence\":0.99}")
check "E body-asserted vertrouwen telt niet -> 403" 403 "$s"

s=$(req GET "/api/memory-core/claims/$CLAIM?workspace=$WS" "$OE_KEY_SERVICE")
lc=$(jq -r '.lifecycle_state // empty' "$BODYFILE")
check "A/E claim staat nog op pending" pending "$lc"

# ── B · wie het feit voedde kan het niet keuren (self-review) ───────────────
s=$(req POST "/api/memory-core/claims/$CLAIM/promote" "$OE_KEY_BRIDGE" "{\"workspace\":\"$WS\"}")
check "B self-review geweigerd -> 403" 403 "$s"

# ── P · een onafhankelijke, geauthenticeerde reviewer keurt op eigen naam ───
s=$(req POST "/api/memory-core/claims/$CLAIM/promote" "$OE_KEY_REVIEWER" "{\"workspace\":\"$WS\"}")
check "P onafhankelijke promotie -> 200" 200 "$s"
v=$(jq -r '.fact.verifier_id // empty' "$BODYFILE")
check "P verifier = geauthenticeerde principal" "user:toets-reviewer" "$v"

# ── C · dezelfde claim twee keer promoveren faalt netjes ────────────────────
s=$(req POST "/api/memory-core/claims/$CLAIM/promote" "$OE_KEY_REVIEWER" "{\"workspace\":\"$WS\"}")
check "C dubbele promotie -> 409" 409 "$s"

# ── D · limit is een echte SQL-grens en de totalen blijven eerlijk ──────────
for i in 1 2 3 4; do
  req POST /api/memory "$OE_KEY_REVIEWER" "{\"content\":\"Toetsfeit nummer $i voor $SLUG.\",\"workspace\":\"$WS\"}" >/dev/null
done
s=$(req GET "/api/memory-core/claim-review?workspace=$WS&review_status=unreviewed&limit=2" "$OE_KEY_SERVICE")
returned=$(jq -r '.returned // empty' "$BODYFILE")
total=$(jq -r '.count // empty' "$BODYFILE")
check "D pagina begrensd op 2" 2 "$returned"
check "D totaal blijft 4" 4 "$total"

# ── F · een niet-admin sleutel kan zichzelf geen sleutels bijmaken ──────────
s=$(req POST /api/auth/keys "$OE_KEY_SERVICE" '{"name":"escalatie"}')
check "F keymint zonder admin-scope -> 403" 403 "$s"

# ── Opruimen (best effort) ──────────────────────────────────────────────────
req POST "/api/workspaces/$WS/archive" "$OE_KEY_ADMIN" '{}' >/dev/null || true

printf '# %d/%d geslaagd\n' "$PASS" "$N"
[ "$FAIL" -eq 0 ]
