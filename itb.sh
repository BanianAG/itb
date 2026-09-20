#!/usr/bin/env bash
#
# itb.sh -- set up and run ITB.
#
#   ./itb.sh                 first run: ask, configure, start. Later: just start.
#   ./itb.sh --reconfigure   ask everything again (keeps a backup of .env)
#   ./itb.sh --check         report what is missing. Changes nothing, starts nothing
#   ./itb.sh --logs          start, then follow the API log
#   ./itb.sh --help
#
# It is safe to run repeatedly: it never overwrites .env or license.json without
# being told to, and --check touches nothing at all.

set -euo pipefail

cd "$(cd "$(dirname "$0")" && pwd)"

MODE=start
FOLLOW_LOGS=no
for arg in "$@"; do
  case "$arg" in
    --check)        MODE=check ;;
    --reconfigure)  MODE=reconfigure ;;
    --logs)         FOLLOW_LOGS=yes ;;
    -h|--help)      sed -n '3,12p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)              echo "unknown option: $arg (try --help)" >&2; exit 2 ;;
  esac
done

if [ -t 1 ]; then B=$'\033[1m'; G=$'\033[32m'; Y=$'\033[33m'; R=$'\033[31m'; N=$'\033[0m'
else B=; G=; Y=; R=; N=; fi
info() { printf '%s==>%s %s\n' "$B" "$N" "$*"; }
ok()   { printf '  %sok%s   %s\n' "$G" "$N" "$*"; }
warn() { printf '  %swarn%s %s\n' "$Y" "$N" "$*"; }
PROBLEMS=0
fail() { PROBLEMS=$((PROBLEMS + 1)); printf '  %sfail%s %s\n' "$R" "$N" "$*"; }
die()  { fail "$*"; exit 1; }

ask() {  # ask <prompt> <default> -> answer on stdout
  local prompt="$1" default="${2:-}" reply
  if [ -n "$default" ]; then printf '  %s [%s]: ' "$prompt" "$default" >&2
  else printf '  %s: ' "$prompt" >&2; fi
  read -r reply || reply=
  printf '%s' "${reply:-$default}"
}

ask_secret() {  # ask_secret <prompt> -> answer on stdout, never echoed
  local prompt="$1" reply
  printf '  %s: ' "$prompt" >&2
  read -rs reply || reply=
  printf '\n' >&2
  printf '%s' "$reply"
}

confirm() {  # confirm <prompt> -> 0 = yes
  local reply
  printf '  %s [y/N]: ' "$1" >&2
  read -r reply || reply=
  case "$reply" in [yY]|[yY][eE][sS]) return 0 ;; *) return 1 ;; esac
}

sha256_of() {  # portable: Linux has sha256sum, macOS has shasum
  if command -v sha256sum >/dev/null 2>&1; then printf '%s' "$1" | sha256sum | cut -d' ' -f1
  elif command -v shasum >/dev/null 2>&1; then printf '%s' "$1" | shasum -a 256 | cut -d' ' -f1
  else return 1; fi
}

random_hex32() {
  if command -v openssl >/dev/null 2>&1; then openssl rand -hex 32
  elif command -v python3 >/dev/null 2>&1; then python3 -c 'import secrets;print(secrets.token_hex(32))'
  elif [ -r /dev/urandom ]; then od -An -tx1 -N32 /dev/urandom | tr -d ' \n'
  else return 1; fi
}

set_env_value() {  # set_env_value <file> <KEY> <value> -- replaces the KEY= line in place
  local file="$1" key="$2" value="$3" tmp
  tmp="$(mktemp)"
  awk -v k="$key" -v v="$value" '
    $0 ~ "^" k "=" { print k "=" v; found = 1; next }
    { print }
    END { if (!found) print k "=" v }
  ' "$file" > "$tmp"
  mv "$tmp" "$file"
}

env_value() {  # env_value <file> <KEY> -> the value, or empty
  [ -f "$1" ] || return 0
  sed -n "s/^$2=//p" "$1" | head -1
}

compose() {  # docker compose, with .env as the ONLY source of configuration
  local args=() key
  if [ -f .env ]; then
    while IFS= read -r key; do
      [ -n "$key" ] && args+=(-u "$key")
    done < <(sed -n 's/^\([A-Za-z_][A-Za-z0-9_]*\)=.*/\1/p' .env)
  fi
  env "${args[@]}" docker compose "$@"
}

# ---------------------------------------------------------------------------
# 1 preflight
# ---------------------------------------------------------------------------
info "Checking what is needed"

command -v docker >/dev/null 2>&1 || die "docker not found on PATH. Install Docker, then run this again."
ok "docker ($(docker --version 2>/dev/null | cut -d, -f1))"

docker compose version >/dev/null 2>&1 \
  || die "\`docker compose\` (v2) not available. The old \`docker-compose\` script is not enough."
ok "docker compose ($(docker compose version --short 2>/dev/null))"

docker info >/dev/null 2>&1 \
  || die "the Docker daemon is not reachable. Start Docker Desktop, or add yourself to the docker group."
ok "the Docker daemon answers"

sha256_of test >/dev/null 2>&1 || warn "no sha256sum/shasum found — you will have to hash the password yourself"

[ -f .env.example ] || die "no .env.example here. Run this from the directory you cloned."

# ---------------------------------------------------------------------------
# 2 configure -- .env
# ---------------------------------------------------------------------------
if [ "$MODE" = check ]; then
  info "Configuration"
  if [ -f .env ]; then
    ok ".env exists"
    for k in ITB_API_TAG ITB_CLIENT_TAG ITB_AUTH_USERS; do
      if [ -n "$(env_value .env "$k")" ]; then ok "$k is set"; else fail "$k is empty — the stack will not start"; fi
    done
    if [ -n "$(env_value .env ITB_CORS_ALLOW_ORIGINS)" ]; then
      ok "ITB_CORS_ALLOW_ORIGINS is set"
    else
      fail "ITB_CORS_ALLOW_ORIGINS is empty — the app loads and cannot reach the API"
    fi
  else
    fail "no .env — run ./itb.sh without --check to create it"
  fi
elif [ ! -f .env ] || [ "$MODE" = reconfigure ]; then
  if [ -f .env ]; then
    cp .env ".env.bak.$(date +%Y%m%d%H%M%S)"
    warn "your .env was copied to .env.bak.* before being rewritten"
  fi
  cp .env.example .env

  info "Configuration -- four answers, then it starts"

  # -- image tags. Both images are public, so their tags can simply be read.
  suggested=""
  if command -v curl >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1; then
    suggested="$(curl -fsSL --max-time 15 \
        'https://hub.docker.com/v2/repositories/banianch/itb-api/tags?page_size=25' 2>/dev/null \
      | python3 -c '
import json,sys,re
try: rows = json.load(sys.stdin).get("results", [])
except Exception: sys.exit()
tags = [r["name"] for r in rows if re.fullmatch(r"v?\d+\.\d+\.\d+", r["name"])]
print(tags[0] if tags else "")' 2>/dev/null || true)"
  fi
  if [ -n "$suggested" ]; then
    ok "newest released tag on Docker Hub: $suggested"
  else
    warn "could not read the tag list from Docker Hub — enter the tag by hand"
    echo "        see https://hub.docker.com/u/banianch" >&2
  fi
  tag="$(ask "Version to run" "$suggested")"
  [ -n "$tag" ] || die "no version given. Both images need the same tag."
  set_env_value .env ITB_API_TAG "$tag"
  set_env_value .env ITB_CLIENT_TAG "$tag"

  # -- the account
  echo >&2
  echo "  Exactly one account -- a second one makes the API refuse to start." >&2
  email="$(ask "Your e-mail address (this is the login)")"
  [ -n "$email" ] || die "no e-mail given."
  pw1="$(ask_secret "Password")"
  [ -n "$pw1" ] || die "no password given."
  [ "${#pw1}" -ge 6 ] || die "the password must be at least 6 characters."
  pw2="$(ask_secret "Password again")"
  [ "$pw1" = "$pw2" ] || die "the two passwords differ."
  hash="$(sha256_of "$pw1")" || die "cannot hash the password: no sha256sum or shasum on this system."
  set_env_value .env ITB_AUTH_USERS "$email:$hash"
  unset pw1 pw2
  ok "account configured (the password is stored only as a SHA-256 hash)"

  # -- secrets nobody should have to invent
  if jwt="$(random_hex32)"; then
    set_env_value .env ITB_JWT_SECRET "$jwt"
    set_env_value .env ITB_CREDENTIAL_KEY "$(random_hex32)"
    ok "session key and credential key generated"
  else
    warn "no openssl/python3/urandom — ITB_JWT_SECRET stays empty, so a restart logs you out"
  fi

  # -- the port
  echo >&2
  port="$(ask "HTTP port" "80")"
  set_env_value .env ITB_HTTP_PORT "$port"
  if [ "$port" != "80" ]; then
    set_env_value .env ITB_API_URL "http://api.itb.localhost:$port"
    set_env_value .env ITB_CORS_ALLOW_ORIGINS "http://itb.localhost:$port"
    ok "port $port -- the browser URL and the allowed origin were adjusted with it"
  fi

  ok ".env written"
else
  ok ".env exists (use --reconfigure to answer the questions again)"
fi

# ---------------------------------------------------------------------------
# 3 licence -- the one thing this script cannot produce
# ---------------------------------------------------------------------------
info "Licence"
lic="$(env_value .env ITB_LICENSE_FILE)"
lic="${lic:-./license.json}"
if [ -f "$lic" ]; then
  if grep -q '"licType"' "$lic" 2>/dev/null; then
    typ="$(sed -n 's/.*"licType"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$lic" | head -1)"
    valid_to="$(sed -n 's/.*"validTo"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$lic" | head -1)"
    if [ -n "$valid_to" ] && [ "$valid_to" \< "$(date -u +%F)" ]; then
      fail "the licence expired on $valid_to — the API will not start. Get a new one at https://itb.banian.ch/license/"
    else
      ok "licence found (type ${typ:-?}, valid to ${valid_to:-?})"
    fi
  else
    warn "$lic does not look like a licence (no licType field)"
  fi
else
  fail "no licence at $lic"
  cat >&2 <<'EOF'
        The API does not start without one. It is free of charge:
        Get your license at: https://itb.banian.ch/license/
        and save the file you get back as ./license.json
EOF
  [ "$MODE" = check ] || exit 1
fi

# ---------------------------------------------------------------------------
# 4 data directory -- must be writable by the user inside the container
# ---------------------------------------------------------------------------
info "Data directory"
data_dir="$(env_value .env ITB_DATA_DIR)"
data_dir="${data_dir:-./data}"
owner_uid=""
[ -d "$data_dir" ] && owner_uid="$(
  stat -c '%u' "$data_dir" 2>/dev/null || stat -f '%u' "$data_dir" 2>/dev/null || echo ''
)"

if [ ! -d "$data_dir" ]; then
  if [ "$MODE" = check ]; then
    fail "$data_dir does not exist"
  else
    mkdir -p "$data_dir"
    ok "$data_dir created"
    owner_uid="$(stat -c '%u' "$data_dir" 2>/dev/null || stat -f '%u' "$data_dir" 2>/dev/null || echo '')"
  fi
fi

if [ -d "$data_dir" ] && [ "$owner_uid" != "65532" ]; then
  if [ "$MODE" = check ]; then
    fail "$data_dir is owned by uid ${owner_uid:-?}, not 65532 — the API could not write"
  else
    warn "$data_dir is owned by uid ${owner_uid:-?}; the container writes as uid 65532"
    echo "        sudo chown -R 65532:65532 $data_dir" >&2
    if confirm "Run that now?"; then
      sudo chown -R 65532:65532 "$data_dir" && ok "$data_dir now belongs to uid 65532"
    else
      warn "skipped. ITB will start but will not be able to save."
      echo "        The alternative is to run the API as root: add" >&2
      echo "        user: \"0:0\" to the itb-api service in docker-compose.yml" >&2
    fi
  fi
else
  [ -d "$data_dir" ] && ok "$data_dir belongs to uid 65532"
fi

# ---------------------------------------------------------------------------
# 5 start
# ---------------------------------------------------------------------------
if [ "$MODE" = check ]; then
  if [ "$PROBLEMS" -gt 0 ]; then
    info "$PROBLEMS problem(s) found — nothing was changed and nothing was started"
    exit 1
  fi
  info "Everything needed is in place — nothing was changed and nothing was started"
  exit 0
fi

info "Starting"
if ! compose pull --quiet 2>/dev/null; then
  if ! compose pull; then
    fail "could not pull the images."
    echo "        If the tag does not exist, the tags are listed at" >&2
    echo "        https://hub.docker.com/u/banianch -- then ./itb.sh --reconfigure" >&2
    exit 1
  fi
fi
compose up -d

port="$(env_value .env ITB_HTTP_PORT)"; port="${port:-80}"
if [ "$port" = "80" ]; then base="http://itb.localhost"; api="http://api.itb.localhost"
else base="http://itb.localhost:$port"; api="http://api.itb.localhost:$port"; fi

printf '\n'
info "ITB is starting"
printf '    %-34s the modeller\n'      "$base"
printf '    %-34s the user guide\n'    "$base/user-docs/"
printf '    %-34s the API reference\n' "$api/docs"
printf '\n'
echo "  The API verifies the licence before it serves anything, so give it a few"
echo "  seconds. If it does not come up:"
echo "      docker compose logs itb-api"
printf '\n'

if [ "$FOLLOW_LOGS" = yes ]; then
  compose logs -f itb-api
fi
