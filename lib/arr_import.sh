#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# assemblrr existing-library media importer for Radarr & Sonarr
# Requires: lib/core.sh, lib/api.sh, lib/arr_quality.sh

if [ -n "${_ASSEMBLRR_ARR_IMPORT_SOURCED:-}" ]; then
    return 0
fi
readonly _ASSEMBLRR_ARR_IMPORT_SOURCED=1

_folder_year() {
    local name="$1"
    if [[ "$name" =~ \(([0-9]{4})\)$ ]]; then
        echo "${BASH_REMATCH[1]}"
    fi
}

_folder_title_guess() {
    local name="$1"
    echo "$name" | sed -E 's/[[:space:]]*\([0-9]{4}\)[[:space:]]*$//'
}

import_radarr_existing_media() {
    local apikey="$1"
    local port=7878
    local root_json existing_movies profile_info profile_id
    local added=0 skipped=0 failed=0
    local folder_path folder_name year title_guess
    local lookup_json match payload result movie_id

    root_json=$(api_get "$port" "/api/v3/rootfolder" "$apikey" || echo "[]")
    if [ -z "$root_json" ] || [ "$root_json" = "[]" ]; then
        log_step_fail "Radarr: no root folders — skip existing media import"
        return 1
    fi

    profile_info=$(lookup_radarr_profile "$apikey")
    profile_id=${profile_info%%:*}
    profile_id=${profile_id:-1}

    existing_movies=$(api_get "$port" "/api/v3/movie" "$apikey" || echo "[]")

    while IFS=$'\t' read -r folder_path folder_name; do
        [ -z "$folder_path" ] && continue
        year=$(_folder_year "$folder_name")
        title_guess=$(_folder_title_guess "$folder_name")

        if printf '%s' "$existing_movies" | jq -e --arg p "$folder_path" 'any(.[]; .path == $p)' >/dev/null 2>&1; then
            skipped=$((skipped + 1))
            continue
        fi

        local term="$title_guess" enc_term
        [ -n "$year" ] && term="${title_guess} ${year}"
        enc_term=$(urlencode "$term")
        lookup_json=$(api_get "$port" "/api/v3/movie/lookup?term=${enc_term}" "$apikey" || echo "[]")

        if [ -z "$lookup_json" ] || [ "$lookup_json" = "[]" ]; then
            log_step_fail "Radarr: no match for '${folder_name}'"
            failed=$((failed + 1))
            continue
        fi

        match=$(printf '%s' "$lookup_json" | jq -c --argjson y "${year:-0}" '
            if $y > 0 then ([.[] | select(.year == $y)] | .[0]) // .[0]
            else .[0] end
        ' 2>/dev/null || echo "")

        if [ -z "$match" ] || [ "$match" = "null" ]; then
            log_step_fail "Radarr: could not pick match for '${folder_name}'"
            failed=$((failed + 1))
            continue
        fi

        payload=$(printf '%s' "$match" | jq -c \
            --argjson qid "$profile_id" \
            --arg path "$folder_path" \
            --arg root "/data/media/movies" '
            {
              title: .title,
              tmdbId: .tmdbId,
              year: .year,
              qualityProfileId: $qid,
              monitored: true,
              minimumAvailability: (.minimumAvailability // "announced"),
              rootFolderPath: $root,
              path: $path,
              addOptions: { searchForMovie: false }
            }' 2>/dev/null || echo "")

        if [ -z "$payload" ]; then
            failed=$((failed + 1))
            continue
        fi

        result=$(api_post "$port" "/api/v3/movie" "$apikey" "$payload" || echo "")
        movie_id=$(printf '%s' "$result" | jq -r '.id // empty' 2>/dev/null || echo "")
        if [ -z "$movie_id" ]; then
            if printf '%s' "$result" | jq -e '.message' 2>/dev/null | grep -qi 'exist\|already' 2>/dev/null; then
                skipped=$((skipped + 1))
            else
                log_step_fail "Radarr: import failed for '${folder_name}'"
                failed=$((failed + 1))
            fi
            continue
        fi

        api_post "$port" "/api/v3/command" "$apikey" \
            "{\"name\":\"RescanMovie\",\"movieId\":${movie_id}}" >/dev/null 2>&1 || true
        added=$((added + 1))
        log_step "Radarr: imported existing '${folder_name}' (id ${movie_id}, profile ${profile_id})"
    done < <(printf '%s' "$root_json" | jq -r '.[] | .unmappedFolders[]? | "\(.path)\t\(.name)"' 2>/dev/null || true)

    if [ "$added" -eq 0 ] && [ "$failed" -eq 0 ]; then
        log_step "Radarr: no unmapped movie folders to import"
        return 0
    fi
    log_step "Radarr: existing media import done (added=${added}, skipped=${skipped}, failed=${failed})"
    [ "$failed" -eq 0 ]
}

import_sonarr_existing_media() {
    local apikey="$1"
    local port=8989
    local root_json existing_series profile_info profile_id
    local added=0 skipped=0 failed=0
    local folder_path folder_name year title_guess
    local lookup_json match payload result series_id language_profile_id

    root_json=$(api_get "$port" "/api/v3/rootfolder" "$apikey" || echo "[]")
    if [ -z "$root_json" ] || [ "$root_json" = "[]" ]; then
        log_step_fail "Sonarr: no root folders — skip existing media import"
        return 1
    fi

    profile_info=$(lookup_sonarr_profile "$apikey")
    profile_id=${profile_info%%:*}
    profile_id=${profile_id:-1}

    # Sonarr v3 required languageProfileId; Sonarr v4 ignores/deprecates it. Query best-effort.
    language_profile_id=$(api_get "$port" "/api/v3/languageprofile" "$apikey" 2>/dev/null | jq -r '.[0].id // 1' 2>/dev/null || echo "1")
    [ -n "$language_profile_id" ] || language_profile_id=1

    existing_series=$(api_get "$port" "/api/v3/series" "$apikey" || echo "[]")

    while IFS=$'\t' read -r folder_path folder_name; do
        [ -z "$folder_path" ] && continue
        year=$(_folder_year "$folder_name")
        title_guess=$(_folder_title_guess "$folder_name")

        if printf '%s' "$existing_series" | jq -e --arg p "$folder_path" 'any(.[]; .path == $p)' >/dev/null 2>&1; then
            skipped=$((skipped + 1))
            continue
        fi

        local enc_term
        enc_term=$(urlencode "$title_guess")
        lookup_json=$(api_get "$port" "/api/v3/series/lookup?term=${enc_term}" "$apikey" || echo "[]")

        if [ -z "$lookup_json" ] || [ "$lookup_json" = "[]" ]; then
            log_step_fail "Sonarr: no match for '${folder_name}'"
            failed=$((failed + 1))
            continue
        fi

        match=$(printf '%s' "$lookup_json" | jq -c --argjson y "${year:-0}" '
            if $y > 0 then ([.[] | select(.year == $y)] | .[0]) // .[0]
            else .[0] end
        ' 2>/dev/null || echo "")

        if [ -z "$match" ] || [ "$match" = "null" ]; then
            failed=$((failed + 1))
            continue
        fi

        payload=$(printf '%s' "$match" | jq -c \
            --argjson qid "$profile_id" \
            --argjson lid "$language_profile_id" \
            --arg path "$folder_path" \
            --arg root "/data/media/tv" '
            . + {
              qualityProfileId: $qid,
              languageProfileId: $lid,
              rootFolderPath: $root,
              path: $path,
              monitored: true,
              seasonFolder: true,
              addOptions: {
                searchForMissingEpisodes: false,
                searchForCutoffUnmetEpisodes: false,
                monitor: "all"
              }
            } | del(.id, .statistics, .episodesChanged)
        ' 2>/dev/null || echo "")

        if [ -z "$payload" ]; then
            failed=$((failed + 1))
            continue
        fi

        result=$(api_post "$port" "/api/v3/series" "$apikey" "$payload" || echo "")
        series_id=$(printf '%s' "$result" | jq -r '.id // empty' 2>/dev/null || echo "")
        if [ -z "$series_id" ]; then
            log_step_fail "Sonarr: import failed for '${folder_name}'"
            failed=$((failed + 1))
            continue
        fi

        api_post "$port" "/api/v3/command" "$apikey" \
            "{\"name\":\"RescanSeries\",\"seriesId\":${series_id}}" >/dev/null 2>&1 || true
        added=$((added + 1))
        log_step "Sonarr: imported existing '${folder_name}' (id ${series_id}, profile ${profile_id})"
    done < <(printf '%s' "$root_json" | jq -r '.[] | .unmappedFolders[]? | "\(.path)\t\(.name)"' 2>/dev/null || true)

    if [ "$added" -eq 0 ] && [ "$failed" -eq 0 ]; then
        log_step "Sonarr: no unmapped series folders to import"
        return 0
    fi
    log_step "Sonarr: existing media import done (added=${added}, skipped=${skipped}, failed=${failed})"
    [ "$failed" -eq 0 ]
}
