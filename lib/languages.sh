#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# assemblrr shared ISO 639 language tables and subtitle-language helpers

if [ -n "${_ASSEMBLRR_LANGUAGES_SOURCED:-}" ]; then
    return 0
fi
readonly _ASSEMBLRR_LANGUAGES_SOURCED=1

# Stored picker codes, preferred first. SUBTITLE_LANGUAGES="eng,ell" wins;
# otherwise SUBTITLE_LANGUAGE (legacy single value).
_subtitle_stored_lang_codes() {
    local raw="${SUBTITLE_LANGUAGES:-${SUBTITLE_LANGUAGE:-}}"
    raw=${raw// /}
    [ -z "$raw" ] && return 0
    echo "$raw" | tr ',' '\n' | awk 'NF && !seen[$0]++'
}

# $1 = preferred code; remaining args = full set. Prints comma-separated, preferred first, unique.
_subtitle_join_preferred_first() {
    local preferred="${1:-}"
    shift || true
    local -a out=()
    local c
    [ -n "$preferred" ] && out+=("$preferred")
    for c in "$@"; do
        [ -z "$c" ] && continue
        [ "$c" = "$preferred" ] && continue
        out+=("$c")
    done
    (IFS=,; echo "${out[*]}")
}

# Map ISO 639-2/T, 639-2/B, or 639-1 → ISO 639-1 two-letter code (defaults to "en" on empty).
iso639_to_code2() {
    local code="${1:-en}"
    code=${code%%$'\t'*}
    code=${code// /}
    code=$(printf '%s' "$code" | tr '[:upper:]' '[:lower:]')
    case "$code" in
        ""|"none") echo "en"; return ;;
        [a-z][a-z]) echo "$code"; return ;;
        aar) echo "aa" ;; abk) echo "ab" ;; afr) echo "af" ;; aka) echo "ak" ;;
        alb|sqi) echo "sq" ;; amh) echo "am" ;; ara) echo "ar" ;; arg) echo "an" ;;
        arm|hye) echo "hy" ;; asm) echo "as" ;; ava) echo "av" ;; ave) echo "ae" ;;
        aym) echo "ay" ;; aze) echo "az" ;; bak) echo "ba" ;; bam) echo "bm" ;;
        baq|eus) echo "eu" ;; bel) echo "be" ;; ben) echo "bn" ;; bih) echo "bh" ;;
        bis) echo "bi" ;; bos) echo "bs" ;; bre) echo "br" ;; bul) echo "bg" ;;
        bur|mya) echo "my" ;; cat) echo "ca" ;; cha) echo "ch" ;; che) echo "ce" ;;
        chi|zho) echo "zh" ;; chu) echo "cu" ;; chv) echo "cv" ;; cor) echo "kw" ;;
        cos) echo "co" ;; cre) echo "cr" ;; cze|ces) echo "cs" ;; dan) echo "da" ;;
        div) echo "dv" ;; dut|nld) echo "nl" ;; dzo) echo "dz" ;; ell|gre) echo "el" ;;
        eng) echo "en" ;; epo) echo "eo" ;; est) echo "et" ;; ewe) echo "ee" ;;
        fao) echo "fo" ;; fij) echo "fj" ;; fin) echo "fi" ;; fra|fre) echo "fr" ;;
        fry) echo "fy" ;; ful) echo "ff" ;; geo|kat) echo "ka" ;; ger|deu) echo "de" ;;
        gla) echo "gd" ;; gle) echo "ga" ;; glg) echo "gl" ;; glv) echo "gv" ;;
        grn) echo "gn" ;; guj) echo "gu" ;; hat) echo "ht" ;; hau) echo "ha" ;;
        heb) echo "he" ;; her) echo "hz" ;; hin) echo "hi" ;; hmo) echo "ho" ;;
        hrv) echo "hr" ;; hun) echo "hu" ;; ibo) echo "ig" ;; ice|isl) echo "is" ;;
        ido) echo "io" ;; iii) echo "ii" ;; iku) echo "iu" ;; ile) echo "ie" ;;
        ina) echo "ia" ;; ind) echo "id" ;; ipk) echo "ik" ;; ita) echo "it" ;;
        jav) echo "jv" ;; jpn) echo "ja" ;; kal) echo "kl" ;; kan) echo "kn" ;;
        kas) echo "ks" ;; kau) echo "kr" ;; kaz) echo "kk" ;; khm) echo "km" ;;
        kik) echo "ki" ;; kin) echo "rw" ;; kir) echo "ky" ;; kom) echo "kv" ;;
        kon) echo "kg" ;; kor) echo "ko" ;; kua) echo "kj" ;; kur) echo "ku" ;;
        lao) echo "lo" ;; lat) echo "la" ;; lav) echo "lv" ;; lim) echo "li" ;;
        lin) echo "ln" ;; lit) echo "lt" ;; ltz) echo "lb" ;; lub) echo "lu" ;;
        lug) echo "lg" ;; mac|mkd) echo "mk" ;; mah) echo "mh" ;; mal) echo "ml" ;;
        mao|mri) echo "mi" ;; mar) echo "mr" ;; may|msa) echo "ms" ;; mlg) echo "mg" ;;
        mlt) echo "mt" ;; mon) echo "mn" ;; nau) echo "na" ;; nav) echo "nv" ;;
        nbl) echo "nr" ;; nde) echo "nd" ;; ndo) echo "ng" ;; nep) echo "ne" ;;
        nno) echo "nn" ;; nob) echo "nb" ;; nor) echo "no" ;; nya) echo "ny" ;;
        oci) echo "oc" ;; oji) echo "oj" ;; ori) echo "or" ;; orm) echo "om" ;;
        oss) echo "os" ;; pan) echo "pa" ;; per|fas) echo "fa" ;; pli) echo "pi" ;;
        pol) echo "pl" ;; por) echo "pt" ;; pus) echo "ps" ;; que) echo "qu" ;;
        roh) echo "rm" ;; ron|rum) echo "ro" ;; run) echo "rn" ;; rus) echo "ru" ;;
        sag) echo "sg" ;; san) echo "sa" ;; sin) echo "si" ;; slo|slk) echo "sk" ;;
        slv) echo "sl" ;; sme) echo "se" ;; smo) echo "sm" ;; sna) echo "sn" ;;
        snd) echo "sd" ;; som) echo "so" ;; sot) echo "st" ;; spa) echo "es" ;;
        srd) echo "sc" ;; srp) echo "sr" ;; ssw) echo "ss" ;; sun) echo "su" ;;
        swa) echo "sw" ;; swe) echo "sv" ;; tah) echo "ty" ;; tam) echo "ta" ;;
        tat) echo "tt" ;; tel) echo "te" ;; tgk) echo "tg" ;; tgl) echo "tl" ;;
        tha) echo "th" ;; tib|bod) echo "bo" ;; tir) echo "ti" ;; ton) echo "to" ;;
        tsn) echo "tn" ;; tso) echo "ts" ;; tuk) echo "tk" ;; tur) echo "tr" ;;
        twi) echo "tw" ;; uig) echo "ug" ;; ukr) echo "uk" ;; urd) echo "ur" ;;
        uzb) echo "uz" ;; ven) echo "ve" ;; vie) echo "vi" ;; vol) echo "vo" ;;
        wel|cym) echo "cy" ;; wln) echo "wa" ;; wol) echo "wo" ;; xho) echo "xh" ;;
        yid) echo "yi" ;; yor) echo "yo" ;; zha) echo "za" ;; zul) echo "zu" ;;
        *) echo "$code" ;;
    esac
}

# Map ISO 639-1 two-letter (or 639-2/B) → ISO 639-2/T three-letter code (Jellyfin format).
iso639_to_code3() {
    local code="${1:-en}"
    code=${code%%$'\t'*}
    code=${code// /}
    code=$(printf '%s' "$code" | tr '[:upper:]' '[:lower:]')
    case "$code" in
        ""|"none") echo "eng"; return ;;
        alb) echo "sqi"; return ;; arm) echo "hye"; return ;; baq) echo "eus"; return ;;
        bur) echo "mya"; return ;; chi) echo "zho"; return ;; cze) echo "ces"; return ;;
        dut) echo "nld"; return ;; fre) echo "fra"; return ;; geo) echo "kat"; return ;;
        ger) echo "deu"; return ;; gre) echo "ell"; return ;; ice) echo "isl"; return ;;
        mac) echo "mkd"; return ;; mao) echo "mri"; return ;; may) echo "msa"; return ;;
        per) echo "fas"; return ;; rum) echo "ron"; return ;; slo) echo "slk"; return ;;
        tib) echo "bod"; return ;; wel) echo "cym"; return ;;
        [a-z][a-z][a-z]) echo "$code"; return ;;
        aa) echo "aar" ;; ab) echo "abk" ;; af) echo "afr" ;; ak) echo "aka" ;;
        am) echo "amh" ;; an) echo "arg" ;; ar) echo "ara" ;; as) echo "asm" ;;
        av) echo "ava" ;; ae) echo "ave" ;; ay) echo "aym" ;; az) echo "aze" ;;
        ba) echo "bak" ;; be) echo "bel" ;; bg) echo "bul" ;; bh) echo "bih" ;;
        bi) echo "bis" ;; bm) echo "bam" ;; bn) echo "ben" ;; bo) echo "bod" ;;
        br) echo "bre" ;; bs) echo "bos" ;; ca) echo "cat" ;; ce) echo "che" ;;
        ch) echo "cha" ;; co) echo "cos" ;; cr) echo "cre" ;; cs) echo "ces" ;;
        cu) echo "chu" ;; cv) echo "chv" ;; cy) echo "cym" ;; da) echo "dan" ;;
        de) echo "deu" ;; dv) echo "div" ;; dz) echo "dzo" ;; ee) echo "ewe" ;;
        el) echo "ell" ;; en) echo "eng" ;; eo) echo "epo" ;; es) echo "spa" ;;
        et) echo "est" ;; eu) echo "eus" ;; fa) echo "fas" ;; ff) echo "ful" ;;
        fi) echo "fin" ;; fj) echo "fij" ;; fo) echo "fao" ;; fr) echo "fra" ;;
        fy) echo "fry" ;; ga) echo "gle" ;; gd) echo "gla" ;; gl) echo "glg" ;;
        gn) echo "grn" ;; gu) echo "guj" ;; gv) echo "glv" ;; ha) echo "hau" ;;
        he) echo "heb" ;; hi) echo "hin" ;; ho) echo "hmo" ;; hr) echo "hrv" ;;
        ht) echo "hat" ;; hu) echo "hun" ;; hy) echo "hye" ;; hz) echo "her" ;;
        ia) echo "ina" ;; id) echo "ind" ;; ie) echo "ile" ;; ig) echo "ibo" ;;
        ii) echo "iii" ;; ik) echo "ipk" ;; io) echo "ido" ;; is) echo "isl" ;;
        it) echo "ita" ;; iu) echo "iku" ;; ja) echo "jpn" ;; jv) echo "jav" ;;
        ka) echo "kat" ;; kg) echo "kon" ;; ki) echo "kik" ;; kj) echo "kua" ;;
        kk) echo "kaz" ;; kl) echo "kal" ;; km) echo "khm" ;; kn) echo "kan" ;;
        ko) echo "kor" ;; kr) echo "kau" ;; ks) echo "kas" ;; ku) echo "kur" ;;
        kv) echo "kom" ;; kw) echo "cor" ;; ky) echo "kir" ;; la) echo "lat" ;;
        lb) echo "ltz" ;; lg) echo "lug" ;; li) echo "lim" ;; ln) echo "lin" ;;
        lo) echo "lao" ;; lt) echo "lit" ;; lu) echo "lub" ;; lv) echo "lav" ;;
        mg) echo "mlg" ;; mh) echo "mah" ;; mi) echo "mri" ;; mk) echo "mkd" ;;
        ml) echo "mal" ;; mn) echo "mon" ;; mr) echo "mar" ;; ms) echo "msa" ;;
        mt) echo "mlt" ;; my) echo "mya" ;; na) echo "nau" ;; nb) echo "nob" ;;
        nd) echo "nde" ;; ne) echo "nep" ;; ng) echo "ndo" ;; nl) echo "nld" ;;
        nn) echo "nno" ;; no) echo "nor" ;; nr) echo "nbl" ;; nv) echo "nav" ;;
        ny) echo "nya" ;; oc) echo "oci" ;; oj) echo "oji" ;; om) echo "om" ;;
        or) echo "ori" ;; os) echo "oss" ;; pa) echo "pan" ;; pi) echo "pli" ;;
        pl) echo "pol" ;; ps) echo "pus" ;; pt) echo "por" ;; qu) echo "que" ;;
        rm) echo "roh" ;; rn) echo "run" ;; ro) echo "ron" ;; ru) echo "rus" ;;
        rw) echo "kin" ;; sa) echo "san" ;; sc) echo "srd" ;; sd) echo "snd" ;;
        se) echo "sme" ;; sg) echo "sag" ;; si) echo "sin" ;; sk) echo "slk" ;;
        sl) echo "slv" ;; sm) echo "smo" ;; sn) echo "sna" ;; so) echo "som" ;;
        sq) echo "sqi" ;; sr) echo "srp" ;; ss) echo "ssw" ;; st) echo "sot" ;;
        su) echo "sun" ;; sv) echo "swe" ;; sw) echo "swa" ;; ta) echo "tam" ;;
        te) echo "tel" ;; tg) echo "tgk" ;; th) echo "tha" ;; ti) echo "tir" ;;
        tk) echo "tuk" ;; tl) echo "tgl" ;; tn) echo "tsn" ;; to) echo "ton" ;;
        tr) echo "tur" ;; ts) echo "tso" ;; tt) echo "tat" ;; tw) echo "twi" ;;
        ty) echo "tah" ;; ug) echo "uig" ;; uk) echo "ukr" ;; ur) echo "urd" ;;
        uz) echo "uzb" ;; ve) echo "ven" ;; vi) echo "vie" ;; vo) echo "vol" ;;
        wa) echo "wln" ;; wo) echo "wol" ;; xh) echo "xho" ;; yi) echo "yid" ;;
        yo) echo "yor" ;; za) echo "zha" ;; zh) echo "zho" ;; zu) echo "zul" ;;
        *) echo "$code" ;;
    esac
}

# Offline fallback list (ISO 639-2/T<TAB>Name) when GitHub iso6392.txt is unreachable.
iso639_bundled_menu() {
    cat <<'EOF'
ara	Arabic
bul	Bulgarian
cat	Catalan
ces	Czech
dan	Danish
deu	German
ell	Greek
eng	English
est	Estonian
fas	Persian
fin	Finnish
fra	French
heb	Hebrew
hin	Hindi
hrv	Croatian
hun	Hungarian
ind	Indonesian
ita	Italian
jpn	Japanese
kor	Korean
lit	Lithuanian
lav	Latvian
msa	Malay
nld	Dutch
nor	Norwegian
pol	Polish
por	Portuguese
ron	Romanian
rus	Russian
slk	Slovak
slv	Slovenian
spa	Spanish
srp	Serbian
swe	Swedish
tha	Thai
tur	Turkish
ukr	Ukrainian
vie	Vietnamese
zho	Chinese
EOF
}
