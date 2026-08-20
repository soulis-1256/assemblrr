#!/bin/bash
# One quality choice for Radarr, Sonarr, and Seerr.
# Canonical: QUALITY_TIER=uhd|hd|any
#            QUALITY_SOURCE=web|bluray  (movies only; TV is always WEB)
# Older installs only have SEERR_IS_4K / SEERR_DEFAULT_PROFILE (stock *arr ids).
# Missing QUALITY_SOURCE means bluray (legacy HD/UHD Bluray + WEB defaults).

if [ -n "${_ASSEMBLRR_QUALITY_SOURCED:-}" ]; then
    return 0
fi
readonly _ASSEMBLRR_QUALITY_SOURCED=1

quality_tier() {
    case "${QUALITY_TIER:-}" in
        uhd|hd|any)
            echo "$QUALITY_TIER"
            return 0
            ;;
    esac
    if [ "${SEERR_IS_4K:-false}" = "true" ]; then
        echo uhd
    elif [ -n "${SEERR_DEFAULT_PROFILE:-}" ] && \
         [ "${SEERR_DEFAULT_PROFILE}" != "1" ] && \
         [ "${SEERR_DEFAULT_PROFILE}" != "any" ]; then
        echo hd
    else
        echo any
    fi
}

# Movies: web = WEB-only (no Blu-ray upgrades). bluray = TRaSH Bluray + WEB.
quality_source() {
    case "${QUALITY_SOURCE:-}" in
        web|bluray)
            echo "$QUALITY_SOURCE"
            return 0
            ;;
    esac
    echo bluray
}

quality_seerr_is_4k() {
    if [ "$(quality_tier)" = "uhd" ]; then
        echo true
    else
        echo false
    fi
}

quality_wants_named_profile() {
    [ "$(quality_tier)" != "any" ]
}

# $1 = radarr | sonarr
# prints: target_name|stock_fallback
quality_profile_names() {
    local kind="${1:-radarr}"
    case "$(quality_tier)" in
        uhd)
            if [ "$kind" = "sonarr" ]; then
                printf '%s\n' "assemblrr 4K WEB|Ultra-HD"
            elif [ "$(quality_source)" = "web" ]; then
                printf '%s\n' "assemblrr 4K WEB|Ultra-HD"
            else
                printf '%s\n' "assemblrr 4K Bluray + WEB|Ultra-HD"
            fi
            ;;
        hd)
            if [ "$kind" = "sonarr" ]; then
                printf '%s\n' "assemblrr 1080p WEB|HD-1080p"
            elif [ "$(quality_source)" = "web" ]; then
                printf '%s\n' "assemblrr 1080p WEB|HD-1080p"
            else
                printf '%s\n' "assemblrr 1080p Bluray + WEB|HD-1080p"
            fi
            ;;
        *)
            printf '%s\n' "Any|"
            ;;
    esac
}

quality_sync_exports() {
    QUALITY_TIER="$(quality_tier)"
    QUALITY_SOURCE="$(quality_source)"
    SEERR_IS_4K="$(quality_seerr_is_4k)"
    export QUALITY_TIER QUALITY_SOURCE SEERR_IS_4K
}

# stdin: JSON array of {id,name}
# $1 = exact name, $2 = optional stock fallback name
arr_match_quality_profile() {
    local target="$1"
    local stock="${2:-}"
    local profiles matched=""

    profiles=$(cat)
    if [ -n "$target" ] && [ "$target" != "Any" ]; then
        matched=$(echo "$profiles" | jq -r --arg name "$target" \
            '[.[] | select(.name == $name) | "\(.id):\(.name)"] | .[0] // empty' \
            2>/dev/null || true)
        if [ -n "$matched" ]; then
            echo "$matched"
            return 0
        fi
    fi
    if [ -n "$stock" ]; then
        matched=$(echo "$profiles" | jq -r --arg name "$stock" \
            '[.[] | select(.name == $name) | "\(.id):\(.name)"] | .[0] // empty' \
            2>/dev/null || true)
        if [ -n "$matched" ]; then
            echo "$matched"
            return 0
        fi
    fi
    echo "1:Any"
}
