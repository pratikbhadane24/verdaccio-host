#!/usr/bin/env bash
# End-to-end test for Verdaccio host.
# Spins up an isolated compose project, exercises private + public + catch-all
# package paths, verifies persistence, tears down.
#
# Usage:
#   ./tests/e2e.sh                 # full run, isolated stack on port 14873
#   KEEP_STACK=1 ./tests/e2e.sh    # leave stack up after tests for inspection
#   REUSE_STACK=1 ./tests/e2e.sh   # don't recreate, run against existing
#
# Requires: docker, docker compose, npm, curl, python3 (for json parsing)

set -euo pipefail

# --- Config ---
PROJECT="verdaccio-e2e"
PORT="${E2E_PORT:-14873}"
REGISTRY="http://localhost:${PORT}"
SCOPE="@pratikbhadane24"
TEST_USER="e2e-runner"
TEST_PASS="e2e-pass-$(date +%s)"
TEST_EMAIL="e2e@test.local"

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK_DIR="$(mktemp -d -t verdaccio-e2e.XXXXXX)"
NPMRC="${WORK_DIR}/.npmrc"

cd "$REPO_ROOT"

# --- Helpers ---
RED=$'\033[0;31m'; GRN=$'\033[0;32m'; YLW=$'\033[0;33m'; BLD=$'\033[1m'; RST=$'\033[0m'
step()  { echo "${BLD}${YLW}» $*${RST}"; }
pass()  { echo "${GRN}✓${RST} $*"; }
fail()  { echo "${RED}✗ $*${RST}"; exit 1; }

# Compose with isolated project + env overrides allowing multi-user signup.
compose() {
  MAX_USERS=100 \
  VERDACCIO_PORT="$PORT" \
  VERDACCIO_PUBLIC_URL="$REGISTRY" \
  TRUST_PROXY=127.0.0.1 \
    docker compose -p "$PROJECT" "$@"
}

cleanup() {
  local exit_code=$?
  if [[ -z "${KEEP_STACK:-}" ]]; then
    step "Cleanup: tearing down stack + temp dir"
    compose down -v >/dev/null 2>&1 || true
  else
    echo "${YLW}Stack kept running on $REGISTRY (KEEP_STACK=1)${RST}"
  fi
  rm -rf "$WORK_DIR"
  exit "$exit_code"
}
trap cleanup EXIT

# --- Pre-flight ---
step "Pre-flight: docker + npm available"
command -v docker >/dev/null || fail "docker not found"
command -v npm >/dev/null || fail "npm not found"
command -v python3 >/dev/null || fail "python3 not found"
pass "tools present"

# --- Stack up ---
if [[ -z "${REUSE_STACK:-}" ]]; then
  step "Bringing up isolated stack (project=$PROJECT port=$PORT)"
  compose down -v >/dev/null 2>&1 || true
  compose up -d --wait >/dev/null
  pass "stack healthy"
fi

# --- Test 1: Ping ---
step "T1: ping endpoint"
ping_out=$(curl -fsS "${REGISTRY}/-/ping")
[[ "$ping_out" == "{}" ]] || fail "unexpected ping response: $ping_out"
pass "GET /-/ping → {}"

# --- Test 2: Unauthenticated read denied ---
step "T2: unauth request rejected (packages require \$authenticated)"
code=$(curl -s -o /dev/null -w "%{http_code}" "${REGISTRY}/lodash")
[[ "$code" == "401" || "$code" == "403" ]] || fail "expected 401/403, got $code"
pass "unauthenticated GET /lodash → $code"

# --- Test 3: Signup ---
step "T3: create test user via REST"
signup=$(curl -fsS -X PUT \
  -H "Content-Type: application/json" \
  -d "{\"name\":\"$TEST_USER\",\"password\":\"$TEST_PASS\",\"email\":\"$TEST_EMAIL\"}" \
  "${REGISTRY}/-/user/org.couchdb.user:${TEST_USER}")
TOKEN=$(echo "$signup" | python3 -c 'import sys,json;print(json.load(sys.stdin)["token"])')
[[ -n "$TOKEN" && ${#TOKEN} -gt 50 ]] || fail "no token issued: $signup"
pass "user '$TEST_USER' created, JWT issued (len=${#TOKEN})"

# --- Test 4: htpasswd populated with bcrypt ---
step "T4: htpasswd bcrypt entry written"
hp=$(compose exec -T verdaccio cat /verdaccio/storage/htpasswd)
echo "$hp" | grep -qF "${TEST_USER}:\$2a\$12\$" || fail "no bcrypt entry for user. file:\n$hp"
pass "htpasswd bcrypt entry confirmed"

# --- Set up sandboxed npm config ---
step "Writing sandboxed .npmrc at $NPMRC"
cat > "$NPMRC" <<EOF
registry=${REGISTRY}/
${SCOPE}:registry=${REGISTRY}/
//localhost:${PORT}/:_authToken=${TOKEN}
EOF
export NPM_CONFIG_USERCONFIG="$NPMRC"
export NPM_CONFIG_REGISTRY="${REGISTRY}/"
pass ".npmrc isolated"

# --- Test 5: Public proxy via catch-all (no scope) ---
step "T5: public proxy - install lodash via catch-all '**' rule"
mkdir -p "${WORK_DIR}/install-public"
cd "${WORK_DIR}/install-public"
npm init -y >/dev/null
npm install --no-audit --no-fund lodash@4.17.21 >/tmp/e2e-npm.log 2>&1 || { echo "npm command failed:"; cat /tmp/e2e-npm.log; exit 1; }
node -e 'const _=require("lodash"); if(_.chunk([1,2,3,4],2).length!==2) process.exit(1)' \
  || fail "lodash install/require failed"
pass "lodash@4.17.21 installed + functional via uplink npmjs"
cd "$REPO_ROOT"

# --- Test 6: Public proxy via scoped '@*/*' (non-private scope) ---
step "T6: scoped public proxy - install @types/node"
mkdir -p "${WORK_DIR}/install-scoped"
cd "${WORK_DIR}/install-scoped"
npm init -y >/dev/null
npm install --no-audit --no-fund @types/node@20.0.0 >/tmp/e2e-npm.log 2>&1 || { echo "npm command failed:"; cat /tmp/e2e-npm.log; exit 1; }
[[ -f node_modules/@types/node/package.json ]] || fail "@types/node not installed"
pass "@types/node@20.0.0 installed via @*/* uplink"
cd "$REPO_ROOT"

# --- Test 7: Private publish ---
step "T7: publish private package ${SCOPE}/e2e-fixture@0.0.1"
PUB_DIR="${WORK_DIR}/publish-private"
cp -r "${REPO_ROOT}/tests/fixtures/private-pkg" "$PUB_DIR"
cd "$PUB_DIR"
npm publish >/tmp/e2e-npm.log 2>&1 || { echo "npm command failed:"; cat /tmp/e2e-npm.log; exit 1; }
cd "$REPO_ROOT"

# Verify on registry
priv_meta=$(curl -fsS -H "Authorization: Bearer $TOKEN" "${REGISTRY}/${SCOPE}%2Fe2e-fixture")
priv_ver=$(echo "$priv_meta" | python3 -c 'import sys,json;print(json.load(sys.stdin)["dist-tags"]["latest"])')
[[ "$priv_ver" == "0.0.1" ]] || fail "expected version 0.0.1, registry reports $priv_ver"
pass "private package published, registry reports latest=0.0.1"

# --- Test 8: Private install (fresh dir) ---
step "T8: install private package in fresh consumer"
mkdir -p "${WORK_DIR}/install-private"
cd "${WORK_DIR}/install-private"
npm init -y >/dev/null
npm install --no-audit --no-fund "${SCOPE}/e2e-fixture@0.0.1" >/tmp/e2e-npm.log 2>&1 || { echo "npm command failed:"; cat /tmp/e2e-npm.log; exit 1; }
node -e "const m=require('${SCOPE}/e2e-fixture'); if(m.hello()!=='from-private-registry') process.exit(1)" \
  || fail "private package require failed"
pass "private package installed + executes correctly"
cd "$REPO_ROOT"

# --- Test 9: Bump version + republish (catches version-conflict path) ---
step "T9: republish bumped version 0.0.2"
cd "$PUB_DIR"
npm version 0.0.2 --no-git-tag-version >/dev/null
npm publish >/tmp/e2e-npm.log 2>&1 || { echo "npm command failed:"; cat /tmp/e2e-npm.log; exit 1; }
cd "$REPO_ROOT"
priv_meta2=$(curl -fsS -H "Authorization: Bearer $TOKEN" "${REGISTRY}/${SCOPE}%2Fe2e-fixture")
priv_ver2=$(echo "$priv_meta2" | python3 -c 'import sys,json;print(json.load(sys.stdin)["dist-tags"]["latest"])')
[[ "$priv_ver2" == "0.0.2" ]] || fail "expected 0.0.2, got $priv_ver2"
pass "version bump 0.0.2 published"

# --- Test 10: Duplicate version rejected ---
step "T10: republishing same version rejected"
cd "$PUB_DIR"
if npm publish >/tmp/e2e-npm.log 2>&1; then
  echo "expected failure but publish succeeded:"
  cat /tmp/e2e-npm.log
  fail "duplicate publish should have been rejected"
else
  pass "duplicate version correctly rejected (exit $?)"
fi
cd "$REPO_ROOT"

# --- Test 11: Persistence across restart ---
step "T11: data survives container restart"
compose restart >/dev/null
# Wait for healthy again
until [ "$(docker inspect --format='{{.State.Health.Status}}' "${PROJECT}-verdaccio-1" 2>/dev/null)" = "healthy" ]; do
  sleep 2
done
priv_meta3=$(curl -fsS -H "Authorization: Bearer $TOKEN" "${REGISTRY}/${SCOPE}%2Fe2e-fixture")
priv_ver3=$(echo "$priv_meta3" | python3 -c 'import sys,json;print(json.load(sys.stdin)["dist-tags"]["latest"])')
[[ "$priv_ver3" == "0.0.2" ]] || fail "version lost after restart: $priv_ver3"
pass "private package + auth survived restart"

# --- Test 12: Cached uplink hit ---
step "T12: uplink cache hit (lodash served from local cache)"
# verdaccio caches packages; second fetch should be served from disk
curl -fsS -H "Authorization: Bearer $TOKEN" "${REGISTRY}/lodash" >/dev/null
storage_check=$(compose exec -T verdaccio sh -c 'ls /verdaccio/storage/lodash/ 2>/dev/null | head -3' || true)
[[ -n "$storage_check" ]] || fail "lodash not cached on disk"
pass "lodash cached at /verdaccio/storage/lodash (entries: $(echo "$storage_check" | tr '\n' ' '))"

# --- Done ---
echo ""
echo "${GRN}${BLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RST}"
echo "${GRN}${BLD}  E2E PASSED — 12/12 tests green${RST}"
echo "${GRN}${BLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RST}"
