#!/bin/bash
# assemblrr Jellyfin configuration — sourced by config.sh
# Provides: configure_jellyfin, configure_jellyfin_xml_fallback,
#           configure_jellyfin_libraries, configure_jellyfin_notifications
# Requires: lib/core.sh (logging), lib/api.sh (api_get/post helpers),
#           config.sh (_cfg_log_info, log_step, log_step_fail, AUTH_USERNAME, etc.)

set -euo pipefail

# --- Jellyfin configuration ---

configure_jellyfin() {
    local jellyfin_port=8096
    local max_wait=120
    local wait_time=0

    # Step 1: Wait for Jellyfin to be responsive
    echo >&2
    echo -n "Waiting for Jellyfin to start" >&2
    while [ $wait_time -lt $max_wait ]; do
        local http_code
        http_code=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 3 \
            "http://${API_HOST}:${jellyfin_port}/System/Info/Public" 2>/dev/null || echo "000")
        if [ "$http_code" -ge 200 ] && [ "$http_code" -lt 300 ]; then
            break
        fi
        sleep 3
        wait_time=$((wait_time + 3))
        dot_inline
    done
    echo >&2

    if [ $wait_time -ge $max_wait ]; then
        log_step_fail "Jellyfin: not responsive after ${max_wait}s"
        return 1
    fi

    # Step 2: Check if startup wizard is still pending
    local public_info
    public_info=$(curl -sf --connect-timeout 5 \
        "http://${API_HOST}:${jellyfin_port}/System/Info/Public" 2>/dev/null || echo "")

    if [ -n "$public_info" ]; then
        local wizard_complete
        wizard_complete=$(echo "$public_info" | jq -r '.StartupWizardCompleted // ""' 2>/dev/null || echo "")

        if [ "$wizard_complete" = "True" ] || [ "$wizard_complete" = "true" ]; then
            log_step "Jellyfin: startup wizard already completed"
            echo "Configuring Jellyfin libraries" >&2
            configure_jellyfin_libraries
            echo >&2
            return 0
        fi
    fi

    # Step 3: Wait for the default startup user to be initialized
    # Jellyfin creates a placeholder user on first boot; /Startup/User POST
    # will return 500 if we hit it before the default user exists in the DB
    _cfg_log_info "Jellyfin: attempting startup wizard bypass via API..."
    echo >&2
    echo -n "Waiting for Jellyfin startup user to initialize" >&2
    local first_user_wait=0
    while [ $first_user_wait -lt 60 ]; do
        local first_user_resp
        first_user_resp=$(curl -sf --connect-timeout 3 \
            "http://${API_HOST}:${jellyfin_port}/Startup/FirstUser" 2>/dev/null || echo "")
        if [ -n "$first_user_resp" ]; then
            local first_user_name
            first_user_name=$(echo "$first_user_resp" | jq -r '.Name // ""' 2>/dev/null || echo "")
            if [ -n "$first_user_name" ]; then
                break
            fi
        fi
        sleep 3
        first_user_wait=$((first_user_wait + 3))
        dot_inline
    done
    echo >&2

    if [ $first_user_wait -ge 60 ]; then
        log_step_fail "Jellyfin: startup user not initialized after 60s"
        configure_jellyfin_xml_fallback
        return $?
    fi

    # Step 4: Set startup configuration (locale)
    local locale_code
    locale_code=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 5 -X POST \
        -H "Content-Type: application/json" \
        -d '{"UICulture":"en-US","MetadataCountryCode":"US","PreferredMetadataLanguage":"en"}' \
        "http://${API_HOST}:${jellyfin_port}/Startup/Configuration" 2>/dev/null || echo "000")

    if [ "$locale_code" -ge 200 ] && [ "$locale_code" -lt 300 ]; then
        log_step "Jellyfin: set startup locale (en-US)"
    else
        log_step_fail "Jellyfin: failed to set startup locale (HTTP $locale_code)"
    fi

    # Step 5: Set admin user credentials via Startup API
    local escaped_username escaped_password
    escaped_username=$(printf '%s' "$AUTH_USERNAME" | jq -Rs . 2>/dev/null)
    escaped_password=$(printf '%s' "$AUTH_PASSWORD" | jq -Rs . 2>/dev/null)

    # Fallback if jq fails
    escaped_username=${escaped_username:-"\"$AUTH_USERNAME\""}
    escaped_password=${escaped_password:-"\"$AUTH_PASSWORD\""}

    local user_payload="{\"Name\":${escaped_username},\"Password\":${escaped_password},\"EnableAutoLogin\":false}"
    local user_code
    user_code=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 5 -X POST \
        -H "Content-Type: application/json" \
        -d "$user_payload" \
        "http://${API_HOST}:${jellyfin_port}/Startup/User" 2>/dev/null || echo "000")

    if [ "$user_code" -ge 200 ] && [ "$user_code" -lt 300 ]; then
        log_step "Jellyfin: set admin user credentials ($AUTH_USERNAME)"
    else
        log_step_fail "Jellyfin: failed to set admin user via API (HTTP $user_code)"
        configure_jellyfin_xml_fallback
        return $?
    fi

    # Step 6: Complete the startup wizard
    local complete_code
    complete_code=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 5 -X POST \
        -H "Content-Type: application/json" \
        "http://${API_HOST}:${jellyfin_port}/Startup/Complete" 2>/dev/null || echo "000")

    if [ "$complete_code" -ge 200 ] && [ "$complete_code" -lt 300 ]; then
        log_step "Jellyfin: startup wizard completed via API"
    else
        log_step_fail "Jellyfin: failed to complete startup wizard (HTTP $complete_code)"
        configure_jellyfin_xml_fallback
        return $?
    fi

    # Step 7: Verify wizard is complete
    sleep 3
    local verify_info
    verify_info=$(curl -sf --connect-timeout 5 \
        "http://${API_HOST}:${jellyfin_port}/System/Info/Public" 2>/dev/null || echo "")
    local wizard_status
    wizard_status=$(echo "$verify_info" | jq -r '.StartupWizardCompleted // ""' 2>/dev/null || echo "")

    if [ "$wizard_status" = "True" ] || [ "$wizard_status" = "true" ]; then
        log_step "Jellyfin: startup wizard bypass verified"
    else
        log_step_fail "Jellyfin: wizard completion could not be verified via API"
        configure_jellyfin_xml_fallback
        return $?
    fi

    # Step 8: Add media libraries
    echo "Configuring Jellyfin libraries" >&2
    configure_jellyfin_libraries
    echo >&2
}

configure_jellyfin_xml_fallback() {
    local system_xml="$INSTALL_DIR/config/jellyfin/system.xml"
    local max_wait=60
    local wait_time=0

    # Wait for system.xml to appear
    echo >&2
    echo -n "Waiting for Jellyfin system.xml" >&2
    while [ $wait_time -lt $max_wait ]; do
        if [ -f "$system_xml" ]; then
            break
        fi
        sleep 3
        wait_time=$((wait_time + 3))
        dot_inline
    done
    echo >&2

    if [ ! -f "$system_xml" ]; then
        log_step_fail "Jellyfin: system.xml not found after ${max_wait}s"
        return 1
    fi

    # Mark wizard as complete
    if grep -q '<IsStartupWizardCompleted>false</IsStartupWizardCompleted>' "$system_xml" 2>/dev/null; then
        sed -i 's/<IsStartupWizardCompleted>false<\/IsStartupWizardCompleted>/<IsStartupWizardCompleted>true<\/IsStartupWizardCompleted>/g' "$system_xml"
        log_step "Jellyfin: marked startup wizard as complete in system.xml"
    elif grep -q '<IsStartupWizardCompleted>' "$system_xml" 2>/dev/null; then
        sed -i 's/<IsStartupWizardCompleted>[^<]*<\/IsStartupWizardCompleted>/<IsStartupWizardCompleted>true<\/IsStartupWizardCompleted>/g' "$system_xml"
        log_step "Jellyfin: updated IsStartupWizardCompleted in system.xml"
    else
        # Tag doesn't exist — add it before the closing tag
        sed -i 's/<\/ServerConfiguration>/  <IsStartupWizardCompleted>true<\/IsStartupWizardCompleted>\n<\/ServerConfiguration>/' "$system_xml"
        log_step "Jellyfin: added IsStartupWizardCompleted to system.xml"
    fi

    # Restart Jellyfin to apply changes
    docker restart jellyfin 2>/dev/null || true
    log_step "Jellyfin: restarted to apply system.xml changes"

    # Wait for Jellyfin to come back online
    echo >&2
    echo -n "Waiting for Jellyfin to come back online" >&2
    local back_wait=0
    while [ $back_wait -lt 60 ]; do
        if curl -sf --connect-timeout 3 "http://${API_HOST}:8096/health" >/dev/null 2>&1; then
            break
        fi
        sleep 3
        back_wait=$((back_wait + 3))
        dot_inline
    done
    echo >&2
}

configure_jellyfin_libraries() {
    local jellyfin_port=8096

    # Authenticate to get access token
    local auth_response
    auth_response=$(curl -sf --connect-timeout 10 -X POST \
        -H "Content-Type: application/json" \
        -H 'X-Emby-Authorization: MediaBrowser Client="assemblrr", Version="1.0", Device="setup-script", DeviceId="assemblrr-setup"' \
        -d "{\"Username\":\"${AUTH_USERNAME}\",\"Pw\":\"${AUTH_PASSWORD}\"}" \
        "http://${API_HOST}:${jellyfin_port}/Users/AuthenticateByName" 2>/dev/null || echo "")

    if [ -z "$auth_response" ]; then
        log_step_fail "Jellyfin: failed to authenticate for library setup"
        return 1
    fi

    local access_token
    access_token=$(echo "$auth_response" | jq -r '.AccessToken // ""' 2>/dev/null || echo "")

    if [ -z "$access_token" ]; then
        log_step_fail "Jellyfin: failed to get access token"
        return 1
    fi

    local user_id
    user_id=$(echo "$auth_response" | jq -r '.User.Id // ""' 2>/dev/null || echo "")

    # Define media libraries to add
    local -a lib_names=("Movies" "TV Shows")
    local -a lib_types=("movies" "tvshows")
    local -a lib_paths=("/data/media/movies" "/data/media/tv")

    # Only add Music if the host media/music folder exists
    if [ -n "${MEDIA_DIRECTORY:-}" ] && [ -d "${MEDIA_DIRECTORY}/media/music" ]; then
        lib_names+=("Music")
        lib_types+=("music")
        lib_paths+=("/data/media/music")
    fi

    # Fetch existing libraries to avoid duplicates
    local existing_libs
    existing_libs=$(curl -sf --connect-timeout 5 \
        -H "X-Emby-Token: ${access_token}" \
        "http://${API_HOST}:${jellyfin_port}/Library/VirtualFolders" 2>/dev/null || echo "[]")

    # Remove duplicate libraries (same path, different name — e.g. "Movies2")
    local dupe_ids
    dupe_ids=$(echo "$existing_libs" | jq -r '.[] | . as $lib | .Locations[]? as $loc | {"/data/media/movies": "Movies", "/data/media/tv": "TV Shows", "/data/media/music": "Music"}[$loc] as $expected | select($expected and $lib.Name != $expected) | "\(.ItemId)|\(.Name)"' 2>/dev/null || echo "")

    if [ -n "$dupe_ids" ]; then
        while IFS='|' read -r dupe_id dupe_name; do
            curl -sf -o /dev/null -w "" -X DELETE \
                -H "X-Emby-Token: ${access_token}" \
                "http://${API_HOST}:${jellyfin_port}/Items/${dupe_id}" 2>/dev/null
            log_step "Jellyfin: removed duplicate library '${dupe_name}'"
        done <<< "$dupe_ids"
        # Re-fetch after deletions
        existing_libs=$(curl -sf --connect-timeout 5 \
            -H "X-Emby-Token: ${access_token}" \
            "http://${API_HOST}:${jellyfin_port}/Library/VirtualFolders" 2>/dev/null || echo "[]")
    fi

    for i in "${!lib_names[@]}"; do
        local lib_name="${lib_names[$i]}"
        local lib_type="${lib_types[$i]}"
        local lib_path="${lib_paths[$i]}"

        # Check if a library with this name and path already exists
        local lib_exists
        lib_exists=$(echo "$existing_libs" | jq --arg ln "$lib_name" --arg lp "$lib_path" -r 'if [.[] | select(.Name == $ln and (.Locations // [] | index($lp)))][0] then "yes" else "no" end' 2>/dev/null || echo "no")

        if [ "$lib_exists" = "yes" ]; then
            log_step "Jellyfin: ${lib_name} library already exists (${lib_path})"
            continue
        fi

        # URL-encode the name and path for query params
        local enc_name enc_path
        enc_name=$(jq -rn --arg n "$lib_name" '$n | @uri' 2>/dev/null || echo "${lib_name}")
        enc_path=$(jq -rn --arg p "$lib_path" '($p | @uri) | gsub("%2F"; "/")' 2>/dev/null || echo "${lib_path}")

        local add_code
        add_code=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 5 -X POST \
            -H "Content-Type: application/json" \
            -H "X-Emby-Token: ${access_token}" \
            "http://${API_HOST}:${jellyfin_port}/Library/VirtualFolders?name=${enc_name}&collectionType=${lib_type}&paths=${enc_path}&refreshProgress=0" \
            2>/dev/null || echo "000")

        if [ "$add_code" -ge 200 ] && [ "$add_code" -lt 300 ]; then
            log_step "Jellyfin: added ${lib_name} library (${lib_path})"
        else
            log_step_fail "Jellyfin: failed to add ${lib_name} library (HTTP $add_code)"
        fi
    done

    # Set subtitle preference: always show subtitles in user's preferred language
    # Jellyfin's SubtitleLanguagePreference uses ISO 639-2/T three-letter codes
    # (e.g. "eng", "fra", "deu") — NOT locale codes like "en-US" and NOT two-letter
    # codes like "en".  The UI dropdown matches these codes to display language names.
    # We must also GET the full user config first and POST it back modified,
    # otherwise Jellyfin wipes all other user settings.
    if [ -n "$user_id" ]; then
        local sub_lang="${SUBTITLE_LANGUAGE:-en}"

        # Convert ISO 639-1 (two-letter) to ISO 639-2/T (three-letter) code
        # Jellyfin uses ISO 639-2/T (e.g., "eng" not "en"), so we must convert.
        # If Jellyfin starts accepting 639-1 directly, this mapping can be removed.
        local jf_lang
        jf_lang=$(jq -rn --arg sl "$sub_lang" '($sl | ascii_downcase) | if length == 3 then . else ({"aa":"aar","ab":"abk","af":"afr","ak":"aka","am":"amh","an":"arg","ar":"ara","as":"asm","av":"ava","ay":"aym","az":"aze","ba":"bak","be":"bel","bg":"bul","bh":"bih","bi":"bis","bm":"bam","bn":"ben","bo":"bod","br":"bre","bs":"bos","ca":"cat","ce":"che","ch":"cha","co":"cos","cr":"cre","cs":"ces","cu":"chu","cv":"chv","cy":"cym","da":"dan","de":"deu","dv":"div","dz":"dzo","ee":"ewe","el":"ell","en":"eng","eo":"epo","es":"spa","et":"est","eu":"eus","fa":"fas","ff":"ful","fi":"fin","fj":"fij","fo":"fao","fr":"fra","fy":"fry","ga":"gle","gd":"gla","gl":"glg","gn":"grn","gu":"guj","gv":"glv","ha":"hau","he":"heb","hi":"hin","ho":"hmo","hr":"hrv","ht":"hat","hu":"hun","hy":"hye","hz":"her","ia":"ina","id":"ind","ie":"ile","ig":"ibo","ii":"iii","ik":"ipk","io":"ido","is":"isl","it":"ita","iu":"iku","ja":"jpn","jv":"jav","ka":"kat","kg":"kon","ki":"kik","kj":"kua","kk":"kaz","kl":"kal","km":"khm","kn":"kan","ko":"kor","kr":"kau","ks":"kas","ku":"kur","kv":"kom","kw":"cor","ky":"kir","la":"lat","lb":"ltz","lg":"lug","li":"lim","ln":"lin","lo":"lao","lt":"lit","lu":"lub","lv":"lav","mg":"mlg","mh":"mah","mi":"mri","mk":"mkd","ml":"mal","mn":"mon","mr":"mar","ms":"msa","mt":"mlt","my":"mya","na":"nau","nb":"nob","nd":"nde","ne":"nep","ng":"ndo","nl":"nld","nn":"nno","no":"nor","nr":"nbl","nv":"nav","ny":"nya","oc":"oci","oj":"oji","om":"orm","or":"ori","os":"oss","pa":"pan","pi":"pli","pl":"pol","ps":"pus","pt":"por","qu":"que","rm":"roh","rn":"run","ro":"ron","ru":"rus","rw":"kin","sa":"san","sc":"srd","sd":"snd","se":"sme","sg":"sag","si":"sin","sk":"slk","sl":"slv","sm":"smo","sn":"sna","so":"som","sq":"sqi","sr":"srp","ss":"ssw","st":"sot","su":"sun","sv":"swe","sw":"swa","ta":"tam","te":"tel","tg":"tgk","th":"tha","ti":"tir","tk":"tuk","tl":"tgl","tn":"tsn","to":"ton","tr":"tur","ts":"tso","tt":"tat","tw":"twi","ty":"tah","ug":"uig","uk":"ukr","ur":"urd","uz":"uzb","ve":"ven","vi":"vie","vo":"vol","wa":"wln","wo":"wol","xh":"xho","yi":"yid","yo":"yor","za":"zha","zh":"zho","zu":"zul"}[.] // .) end' 2>/dev/null || echo "$sub_lang")

        # GET current config, patch subtitle fields, POST back
        # Note: GET /Users/{id}/Configuration returns 405; must GET /Users/{id} instead
        # and extract the Configuration object, then POST it to /Users/{id}/Configuration
        local user_obj
        user_obj=$(curl -s -H "X-Emby-Token: ${access_token}" \
            "http://${API_HOST}:${jellyfin_port}/Users/${user_id}" 2>/dev/null)

        local patched_cfg
        patched_cfg=$(echo "$user_obj" | jq --arg lang "$jf_lang" '.Configuration.SubtitleMode = "Always" | .Configuration.SubtitleLanguagePreference = $lang | .Configuration' 2>/dev/null)

        local sub_pref_code
        sub_pref_code=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 5 -X POST \
            -H "Content-Type: application/json" \
            -H "X-Emby-Token: ${access_token}" \
            -d "$patched_cfg" \
            "http://${API_HOST}:${jellyfin_port}/Users/${user_id}/Configuration" \
            2>/dev/null || echo "000")

        if [ "$sub_pref_code" -ge 200 ] && [ "$sub_pref_code" -lt 300 ]; then
            log_step "Jellyfin: set subtitle preference (Always, ${jf_lang})"
        else
            log_step_fail "Jellyfin: failed to set subtitle preference (HTTP $sub_pref_code)"
        fi
    fi

    # Create an API key for Radarr/Sonarr notification connections
    # POST /Auth/Keys?app=assemblrr returns 204 with no body, so we must
    # create it first, then GET /Auth/Keys to retrieve the actual key value.
    mkdir -p "$INSTALL_DIR/secrets"

    local key_create_code
    key_create_code=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 5 -X POST \
        -H "X-Emby-Token: ${access_token}" \
        "http://${API_HOST}:${jellyfin_port}/Auth/Keys?app=assemblrr" 2>/dev/null || echo "000")

    if [ "$key_create_code" = "204" ] || [ "$key_create_code" = "200" ]; then
        local keys_response
        keys_response=$(curl -s --connect-timeout 5 \
            -H "X-Emby-Token: ${access_token}" \
            "http://${API_HOST}:${jellyfin_port}/Auth/Keys" 2>/dev/null || echo "")

        local jf_api_key
        jf_api_key=$(echo "$keys_response" | jq -r '.Items[] | select(.AppName == "assemblrr") | .AccessToken // ""' 2>/dev/null | head -1 || echo "")

        if [ -n "$jf_api_key" ]; then
            echo -n "$jf_api_key" > "$INSTALL_DIR/secrets/jellyfin_api_key.txt"
            chmod 600 "$INSTALL_DIR/secrets/jellyfin_api_key.txt"
            log_step "Jellyfin: created API key for Radarr/Sonarr connections"
        else
            log_step_fail "Jellyfin: API key created but failed to retrieve value"
        fi
    else
        log_step_fail "Jellyfin: failed to create API key (HTTP $key_create_code)"
    fi
}

# --- Jellyfin notification connections (Radarr/Sonarr → Jellyfin) ---

configure_jellyfin_notifications() {
    local jf_api_key
    jf_api_key=$(cat "$INSTALL_DIR/secrets/jellyfin_api_key.txt" 2>/dev/null || echo "")

    if [ -z "$jf_api_key" ]; then
        log_step_fail "Jellyfin notifications: API key not found — skipping"
        return 1
    fi

    local jf_host="jellyfin"
    local jf_port=8096

    # NOTE: The MediaBrowser/Emby notification type calls /Library/Media/Updated which
    # only refreshes EXISTING items in Jellyfin's DB — it cannot discover NEW files.
    # We use a CustomScript that calls POST /Library/Refresh instead, which performs a
    # full library scan and discovers newly downloaded movies/episodes.

    add_jellyfin_refresh_notif "Radarr" "7878" "$RADARR_API_KEY"
    add_jellyfin_refresh_notif "Sonarr" "8989" "$SONARR_API_KEY"
}

# Add a CustomScript notification to an *arr app that triggers Jellyfin library refresh.
# Usage: add_jellyfin_refresh_notif <app_name> <port> <api_key>
add_jellyfin_refresh_notif() {
    local app_name="$1"
    local port="$2"
    local apikey="$3"

    if [ -z "$apikey" ]; then
        return 0
    fi

    local notifications
    notifications=$(api_get "$port" "/api/v3/notification" "$apikey")
    local existing_id
    existing_id=$(echo "$notifications" | jq -r '.[] | select(.implementation == "CustomScript" and .name == "Jellyfin Refresh") | .id // ""' 2>/dev/null | head -1 || echo "")

    if [ -n "$existing_id" ]; then
        log_step "${app_name}: Jellyfin Refresh script already configured"
        return 0
    fi

    local schema
    schema=$(api_get "$port" "/api/v3/notification/schema" "$apikey")
    local payload
    payload=$(echo "$schema" | jq '
        [.[] | select(.implementation == "CustomScript")][0] |
        .fields = [.fields[] | if .name == "path" then .value = "/scripts/jellyfin-refresh.sh" else . end] |
        .onDownload = true | .onUpgrade = true | .name = "Jellyfin Refresh" | .tags = []
    ' 2>/dev/null || echo "")

    if [ -z "$payload" ]; then
        log_step_fail "${app_name}: CustomScript notification schema not found"
        return 1
    fi

    # Ensure the mounted script is executable. Radarr/Sonarr try to start the
    # process when saving a CustomScript (even with forceSave) and reject the
    # notification with "Permission denied" if the bit is missing.
    if [ -f "$INSTALL_DIR/scripts/jellyfin-refresh.sh" ]; then
        chmod +x "$INSTALL_DIR/scripts/jellyfin-refresh.sh" 2>/dev/null || true
    fi

    local result
    result=$(api_post_force "$port" "/api/v3/notification" "$apikey" "$payload")
    if jq_json_has_key "$result" "id"; then
        log_step "${app_name}: added Jellyfin Refresh script (auto-scan on import)"
    else
        local err_msg
        err_msg=$(echo "$result" | jq -r 'if type == "array" then .[0].errorMessage // empty else .errorMessage // empty end' 2>/dev/null || echo "")
        if [ -n "$err_msg" ]; then
            log_step_fail "${app_name}: failed to add Jellyfin Refresh script (${err_msg})"
        else
            log_step_fail "${app_name}: failed to add Jellyfin Refresh script"
        fi
    fi
}
