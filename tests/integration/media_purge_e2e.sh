#!/bin/bash
# Live e2e: media purge via Seerr API, Jellyfin API, and Radarr API.
# Mutates a real assemblrr install — requires ASSEMBLRR_ALLOW_LIVE_TEST=1.
#
# Uses TMDB 10378 (Big Buck Bunny) with a synthetic hardlinked file + local
# .torrent so no indexer grab is required. Does not delete other library titles.
#
# What it proves:
#   1) Seerr  DELETE /api/v1/media/:id/file  → Radarr + media/ + torrents/ + qB
#   2) Seerr  DELETE /api/v1/request/:id via seerr-gateway → same full cascade
#   3) Jellyfin DELETE /Items/:id             → inotify watch → full purge
#   4) Radarr  DELETE /api/v3/movie/:id       → CustomScript hook → qB cleanup
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/../helpers.sh"

TMDB_ID=10378
TITLE="Big Buck Bunny"
TITLE_YEAR="Big Buck Bunny (2008)"
TORRENT_DIR_NAME="Big.Buck.Bunny.2008.1080p.WEB-DL.e2e"

COOKIE_JAR="${TMPDIR:-/tmp}/assemblrr_media_purge_e2e_qb.cookies"
FAILED=0
INSTALL_DIR=""
MEDIA_DIR=""
RADARR_KEY=""
SEERR_KEY=""
JF_KEY=""
AUTH_USER=""
AUTH_PASS=""

die() { echo "ERROR: $*" >&2; exit 1; }
pass() { echo "  PASS: $*"; }
fail() { echo "  FAIL: $*"; FAILED=$((FAILED + 1)); }

require_live_opt_in() {
    if [ "${ASSEMBLRR_ALLOW_LIVE_TEST:-}" != "1" ]; then
        cat >&2 <<'EOF'
Refusing to run live media-purge e2e.

This adds/deletes a Big Buck Bunny test title on your real install
(Radarr, Seerr, Jellyfin, qBittorrent, disk). Re-run with:

  ASSEMBLRR_ALLOW_LIVE_TEST=1 ./tests/integration/media_purge_e2e.sh

Optional:
  ASSEMBLRR_DIR=/path/to/install
  ASSEMBLRR_CONFIG=/path/to/.assemblrr-config
  QBIT_HOST=127.0.0.1:8081
  API_HOST=127.0.0.1
EOF
        exit 2
    fi
}

api_host() { echo "${API_HOST:-127.0.0.1}"; }

read_key() {
    local f="$1"
    [ -f "$f" ] || return 1
    tr -d '\r\n' <"$f"
}

radarr_xml_key() {
    sed -n 's/.*<ApiKey>\(.*\)<\/ApiKey>.*/\1/p' "$INSTALL_DIR/config/radarr/config.xml" 2>/dev/null | head -1
}

qb_login() {
    qbit_login "$COOKIE_JAR" "$AUTH_USER" "$AUTH_PASS" \
        || die "qBittorrent login failed at ${QBIT_HOST}"
}

qb_names() {
    qbit_api "$COOKIE_JAR" "${QBIT_API}/torrents/info" | jq -r '.[].name // empty' 2>/dev/null || true
}

qb_has_bbb() {
    qb_names | grep -qi 'Buck Bunny' && return 0
    return 1
}

qb_delete_bbb() {
    local hashes
    hashes=$(qbit_api "$COOKIE_JAR" "${QBIT_API}/torrents/info" \
        | jq -r '.[] | select(.name | test("Buck Bunny"; "i")) | .hash' 2>/dev/null || true)
    [ -n "$hashes" ] || return 0
    local h csv=""
    for h in $hashes; do
        [ -n "$csv" ] && csv="${csv}|${h}" || csv="$h"
    done
    qbit_api "$COOKIE_JAR" -d "hashes=${csv}&deleteFiles=true" "${QBIT_API}/torrents/delete" >/dev/null 2>&1 || true
}

radarr_bbb_ids() {
    curl -s "http://$(api_host):7878/api/v3/movie?apikey=${RADARR_KEY}" \
        | jq -r --argjson t "$TMDB_ID" '.[] | select(.tmdbId == $t) | .id' 2>/dev/null || true
}

radarr_bbb_count() {
    radarr_bbb_ids | grep -c . || true
}

cleanup_bbb() {
    local id mid
    for id in $(radarr_bbb_ids); do
        curl -s -X DELETE \
            "http://$(api_host):7878/api/v3/movie/${id}?deleteFiles=true&addImportExclusion=false&apikey=${RADARR_KEY}" \
            >/dev/null 2>&1 || true
    done
    if [ -n "${SEERR_KEY:-}" ]; then
        for mid in $(curl -s "http://$(api_host):5055/api/v1/media?take=100" -H "X-Api-Key: ${SEERR_KEY}" \
            | jq -r --argjson t "$TMDB_ID" '.results[]? | select(.tmdbId == $t) | .id' 2>/dev/null || true); do
            curl -s -X DELETE "http://$(api_host):5055/api/v1/media/${mid}" \
                -H "X-Api-Key: ${SEERR_KEY}" >/dev/null 2>&1 || true
            curl -s -X DELETE "http://$(api_host):5055/api/v1/media/${mid}/file?is4k=false" \
                -H "X-Api-Key: ${SEERR_KEY}" >/dev/null 2>&1 || true
        done
    fi
    rm -rf "${MEDIA_DIR}/torrents/movies/${TORRENT_DIR_NAME}" \
        "${MEDIA_DIR}/media/movies/${TITLE_YEAR}" 2>/dev/null || true
    qb_delete_bbb
}

make_torrent() {
    local root="$1" name="$2" out="$3"
    python3 - "$root" "$name" "$out" <<'PY'
import hashlib, sys
from pathlib import Path
root, name, out = Path(sys.argv[1]), sys.argv[2], Path(sys.argv[3])
files = sorted(p for p in root.rglob("*") if p.is_file())
pl = 262144
blob = b"".join(p.read_bytes() for p in files)
pieces = b"".join(hashlib.sha1(blob[i : i + pl]).digest() for i in range(0, len(blob), pl))
fl = [{"length": p.stat().st_size, "path": list(p.relative_to(root).parts)} for p in files]

def be(x):
    if isinstance(x, int):
        return f"i{x}e".encode()
    if isinstance(x, bytes):
        return f"{len(x)}:".encode() + x
    if isinstance(x, str):
        b = x.encode()
        return f"{len(b)}:".encode() + b
    if isinstance(x, list):
        return b"l" + b"".join(be(i) for i in x) + b"e"
    if isinstance(x, dict):
        o = b"d"
        for k in sorted(x):
            o += be(k) + be(x[k])
        return o + b"e"
    raise TypeError(type(x))

out.write_bytes(
    be(
        {
            "announce": "udp://tracker.opentrackr.org:1337/announce",
            "info": {"name": name, "piece length": pl, "pieces": pieces, "files": fl},
        }
    )
)
print(out)
PY
}

setup_title() {
    cleanup_bbb

    local lookup payload movie_id
    lookup=$(curl -sG "http://$(api_host):7878/api/v3/movie/lookup" \
        --data-urlencode "term=tmdb:${TMDB_ID}" -H "X-Api-Key: ${RADARR_KEY}")
    payload=$(echo "$lookup" | jq -c --argjson t "$TMDB_ID" '
        [.[] | select(.tmdbId == $t)][0]
        + {
            qualityProfileId: 1,
            rootFolderPath: "/data/media/movies",
            monitored: true,
            minimumAvailability: "released",
            addOptions: { searchForMovie: false }
          }
        | del(.id, .folderName, .remotePoster, .images)
    ')
    movie_id=$(curl -s -X POST "http://$(api_host):7878/api/v3/movie?apikey=${RADARR_KEY}" \
        -H "Content-Type: application/json" -d "$payload" | jq -r '.id // empty')
    [ -n "$movie_id" ] || die "failed to add Radarr movie tmdb=${TMDB_ID}"

    mkdir -p "${MEDIA_DIR}/torrents/movies/${TORRENT_DIR_NAME}" \
        "${MEDIA_DIR}/media/movies/${TITLE_YEAR}"
    dd if=/dev/urandom of="${MEDIA_DIR}/torrents/movies/${TORRENT_DIR_NAME}/video.mkv" \
        bs=1M count=2 status=none
    ln "${MEDIA_DIR}/torrents/movies/${TORRENT_DIR_NAME}/video.mkv" \
        "${MEDIA_DIR}/media/movies/${TITLE_YEAR}/${TITLE_YEAR} WEBDL-480p.mkv"

    local torrent_path="${TMPDIR:-/tmp}/assemblrr-e2e-bbb.torrent"
    make_torrent "${MEDIA_DIR}/torrents/movies/${TORRENT_DIR_NAME}" "$TORRENT_DIR_NAME" "$torrent_path" >/dev/null
    qbit_api "$COOKIE_JAR" -H "Referer: http://${QBIT_HOST}" \
        -F "torrents=@${torrent_path}" \
        -F "savepath=/data/torrents/movies" \
        -F "category=movies" \
        -F "skip_checking=true" \
        "${QBIT_API}/torrents/add" >/dev/null

    curl -s -X POST "http://$(api_host):7878/api/v3/command?apikey=${RADARR_KEY}" \
        -H "Content-Type: application/json" \
        -d "{\"name\":\"RescanMovie\",\"movieId\":${movie_id}}" >/dev/null

    local i has_file=false
    for i in $(seq 1 20); do
        has_file=$(curl -s "http://$(api_host):7878/api/v3/movie/${movie_id}?apikey=${RADARR_KEY}" \
            | jq -r '.hasFile // false')
        [ "$has_file" = "true" ] && break
        sleep 1
    done
    [ "$has_file" = "true" ] || die "Radarr did not import test file (movie id ${movie_id})"
    qb_has_bbb || die "qBittorrent missing test torrent"
    echo "$movie_id"
}

assert_fully_gone() {
    local label="$1"
    local radarr_n media_exists torr_exists qb_bbb

    sleep 3
    radarr_n=$(radarr_bbb_count)
    media_exists=0
    torr_exists=0
    [ -e "${MEDIA_DIR}/media/movies/${TITLE_YEAR}" ] && media_exists=1
    [ -e "${MEDIA_DIR}/torrents/movies/${TORRENT_DIR_NAME}" ] && torr_exists=1
    if qb_has_bbb; then qb_bbb=1; else qb_bbb=0; fi

    if [ "$radarr_n" = "0" ] && [ "$media_exists" = "0" ] && [ "$torr_exists" = "0" ] && [ "$qb_bbb" = "0" ]; then
        pass "$label (radarr+media+torrents+qB clean)"
        return 0
    fi
    fail "$label (radarr=${radarr_n} media=${media_exists} torrents=${torr_exists} qb_bbb=${qb_bbb})"
    return 1
}

seerr_media_id_for_tmdb() {
    local mid
    mid=$(curl -s "http://$(api_host):5055/api/v1/media?take=100" -H "X-Api-Key: ${SEERR_KEY}" \
        | jq -r --argjson t "$TMDB_ID" '.results[]? | select(.tmdbId == $t) | .id' | head -1)
    if [ -z "$mid" ]; then
        mid=$(curl -s "http://$(api_host):5055/api/v1/movie/${TMDB_ID}" -H "X-Api-Key: ${SEERR_KEY}" \
            | jq -r '.mediaInfo.id // empty')
    fi
    echo "$mid"
}

seerr_request_id_for_tmdb() {
    curl -s "http://$(api_host):5055/api/v1/request?take=100" -H "X-Api-Key: ${SEERR_KEY}" \
        | jq -r --argjson t "$TMDB_ID" '
            .results[]? | select(.media.tmdbId == $t or .mediaInfo.tmdbId == $t) | .id
          ' 2>/dev/null | head -1
}

ensure_seerr_request_and_media() {
    curl -s -X POST "http://$(api_host):5055/api/v1/request" \
        -H "X-Api-Key: ${SEERR_KEY}" -H "Content-Type: application/json" \
        -d "{\"mediaType\":\"movie\",\"mediaId\":${TMDB_ID},\"is4k\":false}" >/dev/null || true
}

# --- Seerr: DELETE /api/v1/media/:id/file ---
test_seerr_delete_file() {
    echo ""
    echo "=== Seerr DELETE /api/v1/media/:id/file ==="
    local movie_id seerr_media_id code

    movie_id=$(setup_title)
    echo "  Radarr movie id=${movie_id}"

    ensure_seerr_request_and_media

    seerr_media_id=$(seerr_media_id_for_tmdb)
    [ -n "$seerr_media_id" ] || { fail "Seerr has no media row for tmdb=${TMDB_ID}"; return 1; }
    echo "  Seerr media id=${seerr_media_id}"

    code=$(curl -s -o /tmp/assemblrr_seerr_del.body -w "%{http_code}" -X DELETE \
        "http://$(api_host):5055/api/v1/media/${seerr_media_id}/file?is4k=false" \
        -H "X-Api-Key: ${SEERR_KEY}")
    echo "  HTTP ${code}"
    if [ "$code" != "204" ] && [ "$code" != "200" ]; then
        fail "Seerr delete file HTTP ${code}: $(head -c 200 /tmp/assemblrr_seerr_del.body 2>/dev/null || true)"
        return 1
    fi

    # CustomScript is async
    sleep 8
    assert_fully_gone "Seerr delete file cascade"
}

# --- Seerr gateway: DELETE /api/v1/request/:id → media file purge + request gone ---
test_seerr_delete_request_via_gateway() {
    echo ""
    echo "=== Seerr DELETE /api/v1/request/:id (seerr-gateway cascade) ==="
    local movie_id seerr_media_id request_id code purge_hdr detail_hdr

    if ! docker inspect seerr-gateway --format '{{.State.Running}}' 2>/dev/null | grep -q true; then
        fail "seerr-gateway container is not running (upgrade stack / compose base.yaml)"
        return 1
    fi

    movie_id=$(setup_title)
    echo "  Radarr movie id=${movie_id}"

    ensure_seerr_request_and_media
    seerr_media_id=$(seerr_media_id_for_tmdb)
    [ -n "$seerr_media_id" ] || { fail "Seerr has no media row for tmdb=${TMDB_ID}"; return 1; }

    request_id=$(seerr_request_id_for_tmdb)
    if [ -z "$request_id" ]; then
        # Request may already be fulfilled; create a fresh one if API allows
        ensure_seerr_request_and_media
        request_id=$(seerr_request_id_for_tmdb)
    fi
    [ -n "$request_id" ] || { fail "Seerr has no request row for tmdb=${TMDB_ID}"; return 1; }
    echo "  Seerr request id=${request_id} media id=${seerr_media_id}"

    code=$(curl -s -D /tmp/assemblrr_seerr_req_del.hdr -o /tmp/assemblrr_seerr_req_del.body -w "%{http_code}" \
        -X DELETE "http://$(api_host):5055/api/v1/request/${request_id}" \
        -H "X-Api-Key: ${SEERR_KEY}")
    purge_hdr=$(grep -i '^X-Assemblrr-Request-Delete-Purge:' /tmp/assemblrr_seerr_req_del.hdr 2>/dev/null \
        | tail -1 | tr -d '\r' | awk '{print $2}')
    detail_hdr=$(grep -i '^X-Assemblrr-Purge-Detail:' /tmp/assemblrr_seerr_req_del.hdr 2>/dev/null \
        | tail -1 | tr -d '\r' | cut -d' ' -f2-)
    echo "  HTTP ${code} purge=${purge_hdr:-?} detail=${detail_hdr:-?}"

    if [ "$code" != "204" ] && [ "$code" != "200" ]; then
        fail "Seerr delete request HTTP ${code}: $(head -c 200 /tmp/assemblrr_seerr_req_del.body 2>/dev/null || true)"
        return 1
    fi
    if [ "$purge_hdr" != "1" ]; then
        fail "missing X-Assemblrr-Request-Delete-Purge:1 (hit stock Seerr instead of gateway?)"
        return 1
    fi

    # Request row should be gone
    local still
    still=$(curl -s "http://$(api_host):5055/api/v1/request/${request_id}" -H "X-Api-Key: ${SEERR_KEY}" \
        | jq -r '.id // empty' 2>/dev/null || true)
    if [ -n "$still" ]; then
        fail "request ${request_id} still present after delete"
        return 1
    fi
    pass "Seerr request row removed"

    sleep 8
    assert_fully_gone "Seerr delete request cascade (gateway)"
}

# --- Jellyfin: DELETE /Items/:id ---
test_jellyfin_delete_item() {
    echo ""
    echo "=== Jellyfin DELETE /Items/:id ==="
    local movie_id jf_item code i path

    movie_id=$(setup_title)
    echo "  Radarr movie id=${movie_id}"

    curl -s -o /dev/null -X POST "http://$(api_host):8096/Library/Refresh" \
        -H "X-Emby-Token: ${JF_KEY}" || true

    jf_item=""
    for i in $(seq 1 40); do
        jf_item=$(curl -s "http://$(api_host):8096/Items?IncludeItemTypes=Movie&Recursive=true&Fields=Path" \
            -H "X-Emby-Token: ${JF_KEY}" \
            | jq -r --arg p "/data/media/movies/${TITLE_YEAR}" '
                .Items[]? | select((.Path // "") | startswith($p)) | .Id
              ' 2>/dev/null | head -1)
        [ -n "$jf_item" ] && break
        sleep 2
    done
    [ -n "$jf_item" ] || { fail "Jellyfin did not index ${TITLE_YEAR}"; return 1; }
    path=$(curl -s "http://$(api_host):8096/Items/${jf_item}" -H "X-Emby-Token: ${JF_KEY}" \
        | jq -r '.Path // empty' 2>/dev/null || true)
    echo "  Jellyfin item id=${jf_item} path=${path}"

    code=$(curl -s -o /tmp/assemblrr_jf_del.body -w "%{http_code}" -X DELETE \
        "http://$(api_host):8096/Items/${jf_item}" -H "X-Emby-Token: ${JF_KEY}")
    echo "  HTTP ${code}"
    if [ "$code" != "204" ] && [ "$code" != "200" ]; then
        fail "Jellyfin delete HTTP ${code}: $(head -c 200 /tmp/assemblrr_jf_del.body 2>/dev/null || true)"
        return 1
    fi

    # media-purge-watch debounce + purge
    sleep 15
    assert_fully_gone "Jellyfin delete item cascade"
}

# --- Radarr direct delete (CustomScript hook) ---
test_radarr_delete() {
    echo ""
    echo "=== Radarr DELETE /api/v3/movie/:id (purge hook) ==="
    local movie_id code

    movie_id=$(setup_title)
    echo "  Radarr movie id=${movie_id}"

    code=$(curl -s -o /dev/null -w "%{http_code}" -X DELETE \
        "http://$(api_host):7878/api/v3/movie/${movie_id}?deleteFiles=true&addImportExclusion=false&apikey=${RADARR_KEY}")
    echo "  HTTP ${code}"
    [ "$code" = "200" ] || { fail "Radarr delete HTTP ${code}"; return 1; }

    sleep 8
    assert_fully_gone "Radarr delete cascade"
}

# --- main ---
require_live_opt_in

INSTALL_DIR=$(resolve_install_dir) || die "Could not resolve assemblrr install dir"
load_assemblrr_config "$INSTALL_DIR" || true

# shellcheck disable=SC1091
[ -f "$INSTALL_DIR/.env" ] && set -a && source "$INSTALL_DIR/.env" && set +a

MEDIA_DIR="${MEDIA_DIRECTORY:-}"
[ -n "$MEDIA_DIR" ] || MEDIA_DIR="${HOME}/assemblrr-media"
[ -d "$MEDIA_DIR" ] || die "MEDIA_DIRECTORY not found: $MEDIA_DIR"

RADARR_KEY=$(radarr_xml_key)
[ -n "$RADARR_KEY" ] || die "Radarr API key missing"
SEERR_KEY=$(docker exec seerr cat /app/config/settings.json 2>/dev/null | jq -r '.main.apiKey // empty' || true)
[ -n "$SEERR_KEY" ] || SEERR_KEY=$(read_key "$INSTALL_DIR/secrets/seerr_api_key.txt" 2>/dev/null || true)
[ -n "$SEERR_KEY" ] || die "Seerr API key missing (docker seerr settings or secrets)"
JF_KEY=$(read_key "$INSTALL_DIR/secrets/jellyfin_api_key.txt") || die "Jellyfin API key missing"
AUTH_USER=$(read_key "$INSTALL_DIR/secrets/auth_username.txt") || die "auth_username.txt missing"
AUTH_PASS=$(read_key "$INSTALL_DIR/secrets/auth_password.txt") || die "auth_password.txt missing"

# Prerequisites
curl -sf "http://$(api_host):7878/ping" >/dev/null || die "Radarr not reachable"
curl -sf "http://$(api_host):5055/api/v1/settings/public" >/dev/null || die "Seerr (gateway) not reachable on :5055"
curl -sf "http://$(api_host):8096/System/Info/Public" >/dev/null || die "Jellyfin not reachable"
docker inspect media-purge-watch --format '{{.State.Running}}' 2>/dev/null | grep -q true \
    || die "media-purge-watch container is not running"
docker inspect seerr-gateway --format '{{.State.Running}}' 2>/dev/null | grep -q true \
    || die "seerr-gateway container is not running (required for delete-request cascade)"
curl -sf "http://$(api_host):5055/_assemblrr/ready" >/dev/null \
    || die "seerr-gateway /_assemblrr/ready failed"
curl -sf "http://$(api_host):7878/api/v3/notification?apikey=${RADARR_KEY}" \
    | jq -e '[.[] | select(.name == "assemblrr Media Purge" and .onMovieDelete == true)] | length > 0' >/dev/null \
    || die "Radarr Media Purge hook not configured (run upgrade / wiring)"

qb_login
trap 'cleanup_bbb; rm -f "$COOKIE_JAR"' EXIT INT TERM

echo "Install:  $INSTALL_DIR"
echo "Media:    $MEDIA_DIR"
echo "API host: $(api_host)"
echo ""

test_radarr_delete || true
test_seerr_delete_file || true
test_seerr_delete_request_via_gateway || true
test_jellyfin_delete_item || true

cleanup_bbb

echo ""
if [ "$FAILED" -gt 0 ]; then
    echo "media_purge_e2e: FAILED ($FAILED assertion(s))"
    exit 1
fi
echo "media_purge_e2e: OK"
exit 0
