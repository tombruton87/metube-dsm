# MeTube's hooks for the chassis core (sourced by run-core.sh). The core gives:
# say, phase, env_get/env_set, rand, compose, in_volume, cname, svc_up, notify,
# fresh, now, json, wait_ready, make_backup, record_backup, qr_png_b64, MSG,
# VAR, APP, LOG, PKG, PKG_NAME, PKG_TITLE, BUILD, HOST_UID, HOST_GID.
#
# Downloads are added, retried and removed through MeTube's own HTTP API
# (/add, /retry, /delete, /start, /history) on 127.0.0.1. The download folder
# is a folder in a DSM shared folder, mounted at /downloads; the package never
# makes a shared folder, only the subfolder inside one it may write to. Files
# in it are listed and removed inside MeTube's container, as the package's
# user — the same user that wrote them. Free text arrives base64url (*_B64)
# and is checked again here once decoded.

MT=""
MT_REPO=ghcr.io/alexta69/metube; MT_PIN=2026.10.19      # the release this package was tested with
MT_VER_RE='^[0-9]{4}\.[0-9]{2}\.[0-9]{2}(\.[0-9]+)?$'
MT_LANGS=" en de fr es it nl pt pl sv da nb fi cs hu ro el tr ru uk ar he hi ja ko zh-Hans zh-Hant id vi th "
# Failures that usually mean yt-dlp is older than the site's latest change (not a wrong or missing link).
MT_STALE_RE='[Uu]nable to extract|nsig|n challenge|[Ss]ignature|[Ss]ign in to confirm|HTTP Error 403|[Pp]layer response|[Rr]equested format is not available|Precondition check failed|[Uu]pdate yt-dlp|--update'

app_validate() {   # key value → 0 if the value has the key's shape
  case "$1" in
    URLS_B64)         [[ "$2" =~ ^[A-Za-z0-9_-]+$ ]] && (( ${#2} <= 4400 )) ;;   # no {1,4400}: musl caps a repeat at 255
    DL_ID_B64)        [[ "$2" =~ ^[A-Za-z0-9_-]+$ ]] && (( ${#2} <= 1400 )) ;;
    PATHS_B64)        [[ "$2" =~ ^[A-Za-z0-9_-]+$ ]] && (( ${#2} <= 4000 )) ;;
    DL_DIR_B64|DL_FOLDER_B64) [[ "$2" =~ ^[A-Za-z0-9_-]+$ ]] && (( ${#2} <= 700 )) ;;
    DL_KIND)          [[ "$2" =~ ^(video|audio)$ ]] ;;
    DL_QUALITY)       [[ "$2" =~ ^(best|2160|1080|720|480)$ ]] ;;
    DL_VFORMAT)       [[ "$2" =~ ^(mp4|any)$ ]] ;;
    DL_AFORMAT)       [[ "$2" =~ ^(mp3|m4a|opus)$ ]] ;;
    DL_PLAYLIST)      [[ "$2" =~ ^(single|all)$ ]] ;;
    DL_PLLIMIT)       [[ "$2" =~ ^[0-9]{1,3}$ ]] && (( 10#$2 >= 1 && 10#$2 <= 500 )) ;;
    DL_WHICH)         [[ "$2" =~ ^(finished|failed)$ ]] ;;
    CLEAN_DAYS)       [[ "$2" =~ ^[0-9]{1,4}$ ]] && (( 10#$2 <= 3650 )) ;;
    OUT_TPL)          [[ "$2" =~ ^(title|title_id|channel|date)$ ]] ;;
    SUB_MODE)         [[ "$2" =~ ^(off|download|embed)$ ]] ;;
    SUB_LANGS)        langs_ok "$2" ;;
    MAX_DL)           [[ "$2" =~ ^[1-5]$ ]] ;;
    DL_DELFILE|SUB_AUTO|EMBED_THUMB|EMBED_META|LAN_URLS|NOTIFY_DONE|NOTIFY_FAIL) [[ "$2" =~ ^[01]$ ]] ;;
    FIRST_IMAGE)      [[ "$2" == "$MT_REPO:"* && "${2##*:}" =~ $MT_VER_RE ]] ;;   # the tests' way to start from an older release (no wizard page asks it)
    TEST_SHARES)      [[ "$2" =~ ^/[A-Za-z0-9._/-]+$ && "$2" != *..* ]] && (( ${#2} <= 200 )) ;;
    *) return 1 ;;
  esac
}
langs_ok() { local l; [[ -n "$1" ]] || return 1; [[ "$1" =~ ^[A-Za-z+-]+$ ]] && (( ${#1} <= 60 )) || return 1
  IFS=+ read -r -a _l <<< "$1"; (( ${#_l[@]} >= 1 && ${#_l[@]} <= 5 )) || return 1
  for l in "${_l[@]}"; do [[ "$MT_LANGS" == *" $l "* ]] || return 1; done; }

# ------------------------------------------------------------ small helpers
unb64() {   # base64url → text on stdout; 1 if it isn't
  local s=${1//-/+}; s=${s//_//}
  case $(( ${#s} % 4 )) in 2) s+="==" ;; 3) s+="=" ;; 1) return 1 ;; esac
  printf '%s' "$s" | base64 -d 2>/dev/null
}
env_set_q() { local v=${2//\\/\\\\}; v=${v//\"/\\\"}; v=${v//\$/\$\$}; env_set "$1" "\"$v\""; }
env_get_q() { local v; v=$(env_get "$1"); v=${v#\"}; v=${v%\"}; v=${v//\$\$/\$}; v=${v//\\\"/\"}; printf '%s' "${v//\\\\/\\}"; }
version_gt() { [[ "$1" != "$2" && "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -n 1)" == "$1" ]]; }
is_synology() { [[ -f /etc.defaults/VERSION ]]; }
url_ok() { local bad='[[:space:][:cntrl:]]'; [[ "$1" =~ ^https?://[A-Za-z0-9] && ${#1} -le 1000 && ! "$1" =~ $bad ]]; }
mt_url() { echo "http://127.0.0.1:$(env_get HTTP_PORT)"; }
on_off() { [[ "$1" == 1 ]] && echo on || echo off; }

# ------------------------------------------------------------ talking to MeTube
mt_api() {   # method path [json] → the body on stdout; 0 for 2xx and no {"status": "error"}. The body goes through a file, never a command line.
  local d code args; d=$(mktemp -d)
  args=(-s -o "$d/out" -w '%{http_code}' --max-time "${MT_TIMEOUT:-30}" -X "$1")
  [[ -n "${3:-}" ]] && { printf '%s' "$3" > "$d/in"; args+=(-H 'Content-Type: application/json' --data-binary "@$d/in"); }
  code=$(curl "${args[@]}" "$(mt_url)/$2" 2>/dev/null)
  cat "$d/out" 2>/dev/null; local body; body=$(cat "$d/out" 2>/dev/null); rm -rf "$d"
  [[ "$code" =~ ^2 ]] && [[ "$(jq -r 'if type == "object" then (.status // "") else "" end' <<< "$body" 2>/dev/null)" != error ]]
}
mt_why() { local m; m=$(jq -r 'if type == "object" then (.msg // .error // "") else "" end' <<< "$1" 2>/dev/null); [[ -n "$m" ]] || m=$1; printf '%s' "$m" | tr -d '\000-\037' | sed -E 's/^ERROR: //' | cut -c1-220; }
mt_up() { [[ "$(curl -s --max-time 5 "$(mt_url)/version" 2>/dev/null | jq -r '."yt-dlp" // empty' 2>/dev/null)" =~ ^[0-9] ]]; }
app_health() { mt_up; }
mt_versions() {   # → "metube ytdlp", read once per container
  local id; id=$(docker inspect -f '{{.Id}}' "$MT" 2>/dev/null | cut -c1-12); [[ -n "$id" ]] || return 0
  if [[ "$(head -n 1 "$VAR/.mt-version" 2>/dev/null)" != "$id" ]]; then
    local j; j=$(curl -s --max-time 5 "$(mt_url)/version" 2>/dev/null)
    local m y; m=$(jq -r '.version // ""' <<< "$j" 2>/dev/null | tr -cd '0-9A-Za-z.-' | head -c 30); y=$(jq -r '."yt-dlp" // ""' <<< "$j" 2>/dev/null | tr -cd '0-9A-Za-z.-' | head -c 30)
    [[ -n "$y" ]] && printf '%s\n%s\n%s\n' "$id" "$m" "$y" > "$VAR/.mt-version"
  fi
  sed -n '2p;3p' "$VAR/.mt-version" 2>/dev/null | paste -sd' '
}
app_version() { local v; v=$(mt_versions | cut -d' ' -f1); [[ -n "$v" && "$v" != dev ]] && { echo "$v"; return 0; }; local i; i=$(env_get MT_IMAGE); [[ "${i##*:}" =~ $MT_VER_RE ]] && echo "${i##*:}"; true; }
ytdlp_version() { mt_versions | cut -d' ' -f2; }

# ------------------------------------------------------------ the download folder
# A folder in a shared folder: on a Synology /volumeN/<share>/…, never DSM's own @ folders, a recycle bin
# or snapshot, nor this package's own share. On a test box, under TEST_SHARES.
test_shares() { is_synology && return 1; local t; t=$(env_get TEST_SHARES); [[ -n "$t" ]] && echo "$t"; }
path_ok() {
  local p=$1 bad='[[:cntrl:]$"`\\]' t
  [[ "$p" == /?* && "$p" != */ && "$p" != *..* && "$p" != *//* && "$p" != */./* && ${#p} -le 400 && ! "$p" =~ $bad ]] || return 1
  [[ "/$p/" == */@* || "$p" == *"/#recycle"* || "$p" == *"/#snapshot"* ]] && return 1
  if is_synology; then [[ "$p" =~ ^/volume(USB)?[0-9]+(-[0-9]+)?/[^/]+ && ! "$p" =~ ^/volume(USB)?[0-9]+(-[0-9]+)?/$PKG_NAME(/|$) ]] || return 1
  elif t=$(test_shares); then [[ "$p" == "$t"/?* ]] || return 1; fi
  return 0
}
share_root() {   # path → the shared folder it's in (/volume1/Downloads/MeTube → /volume1/Downloads)
  local t
  if is_synology; then [[ "$1" =~ ^(/volume(USB)?[0-9]+(-[0-9]+)?/[^/]+) ]] && echo "${BASH_REMATCH[1]}"; return; fi
  if t=$(test_shares); then local rest=${1#"$t"/}; echo "$t/${rest%%/*}"; return; fi
  echo "$1"
}
default_dl_dir() {   # a Downloads share if there is one, else the first volume's
  local t d
  if t=$(test_shares); then echo "$t/Downloads/MeTube"; return; fi
  for d in /volume1/Downloads /volume1/downloads /volume1/download; do folder_there "$d" && { echo "$d/MeTube"; return; }; done
  echo "/volume1/Downloads/MeTube"
}
# Is it there? Asked of Docker, which sees the NAS's own folders. --mount, not -v: -v would quietly create it.
folder_there() { docker run --rm --mount "type=bind,source=$1,target=/m,readonly" --entrypoint sh "$PKG_NAME-setup:local" -c 'test -d /m' >/dev/null 2>&1; }
# What the package's user may do in a folder (MeTube runs as it): rw, ro or none, tested by writing a file; and the
# subfolder made when it may write (never the shared folder itself — that's DSM's).
ACCESS_SH='p=$1; q=$p; while [ ! -d "$q" ] && [ -n "$q" ] && [ "$q" != / ]; do q=${q%/*}; done; [ -n "$q" ] || q=/
  t="$q/.metube-dsm-write-test.$$"
  if ( : > "$t" ) 2>/dev/null; then rm -f "$t"; a=rw; elif ls "$q" >/dev/null 2>&1; then a=ro; else a=none; fi
  if [ "$a" = rw ] && [ ! -d "$p" ]; then mkdir -p "$p" 2>/dev/null && a=made || a=ro; fi
  echo "$a"'
dl_prepare() {   # DL_DIR → DL_SRC (the folder, or empty for the placeholder) and $VAR/dlstate → 0 when DL_SRC changed
  local p r a state want=""
  p=$(env_get_q DL_DIR); mkdir -p "$APP/no-folder"; chmod 755 "$APP/no-folder"
  if [[ -z "$p" ]] || ! path_ok "$p"; then state=bad
  else r=$(share_root "$p")
    if ! folder_there "$r"; then state=missing
    else a=$(docker run --rm --user "$HOST_UID:$HOST_GID" --mount "type=bind,source=$r,target=$r" --entrypoint sh "$PKG_NAME-setup:local" -c "$ACCESS_SH" sh "$p" 2>/dev/null)
      case "$a" in
        rw) state=ok; want=$p ;;
        made) state=ok; want=$p; say "made the folder $p for downloads (in the shared folder $(basename "$r"))" ;;
        ro) state=readonly ;;
        *) state=noaccess ;;
      esac
    fi
  fi
  printf '%s\n' "$state" > "$VAR/dlstate"
  [[ "$state" == ok ]] || say "the download folder ${p:-?} isn't usable ($state) — $(dl_fix_text "$state" "$p")"
  [[ "$(env_get_q DL_SRC)" == "$want" ]] && return 1
  if [[ -n "$want" ]]; then env_set_q DL_SRC "$want"; else env_set DL_SRC ""; fi
  return 0
}
dl_fix_text() {   # state path → what to do, in DSM's words
  local r; r=$(basename "$(share_root "$2")")
  case "$1" in
    ok) echo "fine" ;;
    bad) echo "pick a folder inside a shared folder, like /volume1/Downloads/MeTube (Defaults tab)." ;;
    missing) echo "the shared folder $r isn't there. Create it in Control Panel → Shared Folder → Create (or pick another folder on the Defaults tab); the package never creates shared folders." ;;
    *) echo "the package's user can't write there. In DSM: Control Panel → Shared Folder → $r → Edit → Permissions → pick \"System internal user\" in the drop-down → $PKG_NAME → tick Read/Write → Save. Then press Check again." ;;
  esac
}

# ------------------------------------------------------------ defaults → MeTube's settings
tpl_of() {   # OUT_TPL preset → MeTube's output template
  case "$1" in
    title_id) echo '%(title)s [%(id)s].%(ext)s' ;;
    channel)  echo '%(uploader,channel|Unknown)s/%(title)s.%(ext)s' ;;
    date)     echo '%(upload_date>%Y-%m-%d|0000-00-00)s %(title)s.%(ext)s' ;;
    *)        echo '%(title)s.%(ext)s' ;;
  esac
}
ytdl_opts_json() {   # subtitles, metadata, SMB-safe names, the download date as the file's date
  jq -n -c --arg mode "$(env_get SUB_MODE)" --arg langs "$(env_get SUB_LANGS)" --arg auto "$(env_get SUB_AUTO)" --arg meta "$(env_get EMBED_META)" '
    {windowsfilenames: true, updatetime: false}
    + (if $mode == "off" then {} else {writesubtitles: true, writeautomaticsub: ($auto == "1"), subtitleslangs: ($langs | split("+")), subtitlesformat: "srt/vtt/best"} end)
    | .postprocessors = ((if $mode == "download" then [{key: "FFmpegSubtitlesConvertor", format: "srt", when: "before_dl"}] else [] end)
        + (if $mode == "embed" then [{key: "FFmpegEmbedSubtitle", already_have_subtitle: false}] else [] end)
        + (if $meta == "1" then [{key: "FFmpegMetadata", add_metadata: true}] else [] end))'
}
ytdl_presets_json() {   # cover art in the file: only where it fits (MP4 video; audio has MeTube's own cover option)
  jq -n -c '{"dsm-cover": {writethumbnail: true, postprocessors: [{key: "FFmpegThumbnailsConvertor", format: "jpg", when: "before_dl"}, {key: "EmbedThumbnail", already_have_thumbnail: false}]}}'
}
# Names compose reads from .env never match a request key: the core exports request keys while it acts, and
# compose takes its environment over .env (MAX_DL and LAN_URLS are request keys; MT_MAX_DL and MT_LAN go to compose).
apply_defaults_env() {   # the .env values MeTube reads, from the window's defaults
  local t; t=$(tpl_of "$(env_get OUT_TPL)")
  env_set_q OUTPUT_TEMPLATE "$t"; env_set_q OUTPUT_TEMPLATE_PLAYLIST "%(playlist_title|Playlist)s/${t##*/}"
  env_set YTDL_OPTS "'$(ytdl_opts_json)'"; env_set YTDL_PRESETS "'$(ytdl_presets_json)'"
}
defaults_json() {
  jq -n -c --arg kind "$(env_get DEF_KIND)" --arg q "$(env_get DEF_QUALITY)" --arg vf "$(env_get DEF_VFORMAT)" --arg af "$(env_get DEF_AFORMAT)" \
    --arg tpl "$(env_get OUT_TPL)" --arg sm "$(env_get SUB_MODE)" --arg sl "$(env_get SUB_LANGS)" --arg sa "$(env_get SUB_AUTO)" \
    --arg et "$(env_get EMBED_THUMB)" --arg em "$(env_get EMBED_META)" --arg mx "$(env_get MT_MAX_DL)" --arg lan "$(env_get MT_LAN)" \
    --arg nd "$(env_get NOTIFY_DONE)" --arg nf "$(env_get NOTIFY_FAIL)" --arg cd "$(env_get CLEAN_DAYS)" \
    '{kind: $kind, quality: $q, vformat: $vf, aformat: $af, tpl: $tpl, sub_mode: $sm, sub_langs: ($sl | split("+")), sub_auto: ($sa == "1"),
      thumb: ($et == "1"), meta: ($em == "1"), max_dl: ($mx | tonumber? // 3), lan: ($lan == "true"),
      notify_done: ($nd == "1"), notify_fail: ($nf == "1"), clean_days: ($cd | tonumber? // 0)}'
}
write_share_page() {   # the page links from a phone or browser go to, served by MeTube itself (same origin, so its /add takes them)
  local cfg tmp; mkdir -p "$APP/www"; chmod 755 "$APP/www"
  cfg=$(defaults_json | jq -c '{kind, quality, vformat, aformat, thumb, meta}')
  tmp=$(mktemp); sed "s|@CONFIG@|$cfg|" "$PKG/setup/share.html" > "$tmp" || { rm -f "$tmp"; return 1; }
  # Written in place, not renamed in: MeTube's container has this very file bind-mounted.
  cmp -s "$tmp" "$APP/www/dsm-share.html" || cat "$tmp" > "$APP/www/dsm-share.html"; rm -f "$tmp"; chmod 644 "$APP/www/dsm-share.html"
}

# ------------------------------------------------------------ lifecycle hooks
app_first_env() {
  local d=""
  [[ -n "${TEST_SHARES:-}" ]] && ! is_synology && env_set TEST_SHARES "$TEST_SHARES"
  env_set MT_IMAGE "${FIRST_IMAGE:-$MT_REPO:$MT_PIN}"
  d=$(unb64 "${DL_DIR_B64:-}" 2>/dev/null) || d=""; path_ok "$d" || d=$(default_dl_dir)
  env_set_q DL_DIR "$d"; env_set DL_SRC ""
  echo "$BUILD" > "$VAR/.floor-build"
  return 0
}
mt_floor() {   # a newer package brings its MeTube with it: the pinned release is the oldest it runs
  local img cur; img=$(env_get MT_IMAGE); cur=${img##*:}
  [[ "$img" == "$MT_REPO:"* && "$cur" =~ $MT_VER_RE ]] || return 0   # someone's own image or tag: left as it is
  version_gt "$MT_PIN" "$cur" && { say "this package brings MeTube $MT_PIN (was $cur)"; env_set MT_IMAGE "$MT_REPO:$MT_PIN"; }
  return 0
}
app_load_env() {
  MT=$(cname server)
  local k v
  for k in DEF_KIND:video DEF_QUALITY:best DEF_VFORMAT:mp4 DEF_AFORMAT:mp3 OUT_TPL:title SUB_MODE:off SUB_LANGS:en SUB_AUTO:0 \
           EMBED_THUMB:1 EMBED_META:1 MT_MAX_DL:3 MT_LAN:false NOTIFY_DONE:0 NOTIFY_FAIL:1 CLEAN_DAYS:0; do
    v=$(env_get "${k%%:*}"); [[ -n "$v" ]] || env_set "${k%%:*}" "${k#*:}"
  done
  [[ -n "$(env_get MT_IMAGE)" ]] || env_set MT_IMAGE "$MT_REPO:$MT_PIN"
  if [[ "$(cat "$VAR/.floor-build" 2>/dev/null)" != "$BUILD" ]]; then [[ -f "$VAR/.floor-build" ]] && mt_floor; echo "$BUILD" > "$VAR/.floor-build"; fi
  apply_defaults_env
}
app_before_up() {
  # MeTube runs as the package's user: its state volume must be that user's.
  in_volume state rw -- "chown $HOST_UID:$HOST_GID /vol && chmod 750 /vol" </dev/null >> "$LOG" 2>&1 || true
  dl_prepare || true
  write_share_page || say "✗ the share page couldn't be written"
  return 0
}
app_after_up() { rm -f "$VAR/.mt-version"; return 0; }
app_after_settings() { write_share_page || true; }
app_settings() { return 1; }   # nothing of its own on Site address

# ------------------------------------------------------------ the library (the download folder's files)
LIB_SH='cd /downloads 2>/dev/null || exit 3
  find . -xdev -type f ! -path "*/.*" -printf "%s\t%T@\t%P\n" 2>/dev/null | sort -t "	" -k2,2nr
  echo "@df	$(df -kP /downloads | awk "NR == 2 {print \$2 \"	\" \$4}")"
  echo "@inc	$(du -sk .incomplete 2>/dev/null | cut -f1)"'
library_scan() {   # → $VAR/library.json: the newest 500 files, totals, free space
  local raw
  svc_up server || return 0
  raw=$(docker exec -u "$HOST_UID:$HOST_GID" "$MT" sh -c "$LIB_SH" 2>/dev/null) || { [[ -n "$raw" ]] || return 0; }
  jq -R -s -c --argjson at "$(now)" '
    split("\n") | map(select(length > 0) | split("\t")) as $rows
    | ($rows | map(select(.[0] | startswith("@") | not)) | map({p: .[2], s: (.[0] | tonumber? // 0), t: (.[1] | tonumber? // 0 | floor)})) as $files
    | ($rows | map(select(.[0] == "@df")) | first // ["", "0", "0"]) as $df
    | ($rows | map(select(.[0] == "@inc")) | first // ["", "0"]) as $inc
    | {at: $at, count: ($files | length), bytes: ($files | map(.s) | add // 0), files: $files[:500],
       disk_total: (($df[1] | tonumber? // 0) * 1024), disk_free: (($df[2] | tonumber? // 0) * 1024), incomplete: ((($inc[1] // "0") | tonumber? // 0) * 1024)}' \
    <<< "$raw" > "$VAR/library.json.tmp" 2>/dev/null && [[ -s "$VAR/library.json.tmp" ]] && for_window "$VAR/library.json"   # the window reads the file list itself
  touch "$VAR/.lib-scanned"
}
rel_ok() {   # a path relative to the download folder: no leading /, no .., no hidden parts, one line
  local p=$1 bad='[[:cntrl:]]'
  [[ -n "$p" && ${#p} -le 400 && "$p" != /* && "$p" != */ && "$p" != *//* && ! "$p" =~ $bad ]] || return 1
  [[ "/$p/" != */../* && "/$p/" != */./* && "/$p" != */.* ]]
}
DEL_SH='cd /downloads || exit 3; for p; do [ -f "$p" ] || continue; rm -f -- "$p" && echo "$p"; d=$(dirname -- "$p"); while [ "$d" != . ] && rmdir -- "$d" 2>/dev/null; do d=$(dirname -- "$d"); done; done'
lib_delete() {   # paths… → MSG
  local out n
  out=$(docker exec -u "$HOST_UID:$HOST_GID" "$MT" sh -c "$DEL_SH" sh "$@" 2>>"$LOG") || true
  n=$(grep -c . <<< "$out" || true)
  say "removed $n file(s) from the download folder"
  library_scan
  MSG="Removed $n of $# file$( (( $# == 1 )) || echo s)."; (( n > 0 ))
}
clean_old() {   # files older than CLEAN_DAYS days go (by the date they were downloaded); then empty folders
  local days out n; days=$(env_get CLEAN_DAYS); [[ "$days" =~ ^[0-9]+$ ]] && (( days > 0 )) || return 0
  svc_up server || return 0
  out=$(docker exec -u "$HOST_UID:$HOST_GID" "$MT" sh -c 'cd /downloads || exit 3
    find . -xdev -type f ! -path "*/.*" -mtime +"$1" -print -delete 2>/dev/null
    find . -xdev -mindepth 1 -type d -empty ! -path "*/.*" -delete 2>/dev/null; true' sh "$(( days - 1 ))" 2>>"$LOG") || true
  n=$(grep -c . <<< "$out" || true); touch "$VAR/.cleaned"
  (( n > 0 )) && say "clean-up: $n file(s) older than $days days were removed from the download folder"
  CLEANED=$n; library_scan
}

# ------------------------------------------------------------ downloads: what MeTube has, notifications
history_json() {   # MeTube's /history, slimmed for the window → stdout
  local h; h=$(MT_TIMEOUT=10 mt_api GET history) || return 1
  printf '%s' "$h" | jq -c '
    def slim: {key: .url, url, title: (.title // ""), status: (.status // ""), percent: (.percent // null), speed: (.speed // null), eta: (.eta // null),
               size: (.size // null), filename: (.filename // null), folder: (.folder // ""), kind: (.download_type // ""), format: (.format // ""), quality: (.quality // ""),
               msg: ((.msg // .error // "") | tostring | sub("^ERROR: "; "") | .[:400]), at: (((.timestamp // 0) / 1000000000) | floor)};
    {queue: ([.queue[]?, .pending[]?] | map(slim)), done: (.done // [] | map(slim) | sort_by(-.at) | .[:300])}' 2>/dev/null
}
watch_downloads() {   # new finished / failed downloads since the last look → notifications, a library rescan, yt-dlp's health
  local h marks seen rows n
  h=$(history_json) || return 0; printf '%s\n' "$h" > "$VAR/.history.json.tmp" && mv "$VAR/.history.json.tmp" "$VAR/.history.json"
  marks=$(jq -c '[.done[] | {(.key): (.status + "@" + (.at | tostring))}] | add // {}' <<< "$h" 2>/dev/null) || return 0
  seen=$(cat "$VAR/.seen.json" 2>/dev/null)
  printf '%s\n' "$marks" > "$VAR/.seen.json.tmp" && mv "$VAR/.seen.json.tmp" "$VAR/.seen.json"
  [[ "$seen" == \{* ]] || return 0   # the first look only sets the marks
  rows=$(jq -c --argjson seen "$seen" '[.done[] | select($seen[.key] != (.status + "@" + (.at | tostring))) | select(.status == "finished" or .status == "error")]' <<< "$h" 2>/dev/null)
  n=$(jq 'length' <<< "${rows:-[]}" 2>/dev/null || echo 0); (( n > 0 )) || return 0
  [[ "$(jq '[.[] | select(.status == "finished")] | length' <<< "$rows")" -gt 0 ]] && library_scan
  # Failures that look like an outdated yt-dlp, kept for a day
  jq -r --arg re "$MT_STALE_RE" '.[] | select(.status == "error" and (.msg | test($re))) | .key' <<< "$rows" | while IFS= read -r _; do now >> "$VAR/.stale"; done
  local cut; cut=$(( $(now) - 86400 )); awk -v c="$cut" '$1 >= c' "$VAR/.stale" 2>/dev/null > "$VAR/.stale.tmp"; mv "$VAR/.stale.tmp" "$VAR/.stale" 2>/dev/null
  local stale; stale=$(stale_count)
  if (( stale >= 2 )); then notify ytdlpold 24 "$stale" "$(ytdlp_version)"; fi
  local nf nd; nf=$(env_get NOTIFY_FAIL); nd=$(env_get NOTIFY_DONE)
  if (( n > 5 )); then
    local f d; f=$(jq '[.[] | select(.status == "error")] | length' <<< "$rows"); d=$(( n - f ))
    [[ "$nf" == 1 ]] && (( f > 0 )) && notify failedmany 0 "$f"
    [[ "$nd" == 1 ]] && (( d > 0 )) && notify donemany 0 "$d"
    return 0
  fi
  jq -r '.[] | [.status, .title, (if .filename then ((if .folder != "" then .folder + "/" else "" end) + .filename) else "" end), .msg] | @tsv' <<< "$rows" |
  while IFS=$'\t' read -r st title file msg; do
    if [[ "$st" == error ]]; then [[ "$nf" == 1 ]] && notify failed 0 "${title:-a download}" "${msg:-no reason given}"
    else [[ "$nd" == 1 ]] && notify done 0 "${title:-a download}" "$(basename "$(env_get_q DL_DIR)")/${file}"; fi
  done
  return 0
}
app_tick() {
  local st; st=$(cat "$VAR/dlstate" 2>/dev/null)
  if [[ "$st" != ok ]] && ! fresh "$VAR/.dl-recheck" 600; then   # waiting for its shared folder, or for permission
    touch "$VAR/.dl-recheck"
    if dl_prepare && [[ "$(cat "$VAR/dlstate")" == ok ]]; then say "the download folder is usable now — MeTube starts again with it"; compose up -d >> "$LOG" 2>&1; wait_ready 180 || true; fi
  fi
  watch_downloads
  if fresh "$VAR/watching" 30; then fresh "$VAR/.lib-scanned" 300 || library_scan; else fresh "$VAR/.lib-scanned" 1800 || library_scan; fi
  fresh "$VAR/.cleaned" 86400 || clean_old
  return 0
}

# ------------------------------------------------------------ what the window shows
stale_count() { local n; n=$(grep -c . "$VAR/.stale" 2>/dev/null); echo "${n:-0}"; }
qr_for() {   # text → base64 PNG, kept per text
  local f; f="$VAR/.qr-$(printf '%s' "$1" | md5sum | cut -c1-12).b64"
  [[ -s "$f" ]] || qr_png_b64 "$1" > "$f"
  cat "$f"
}
app_status() {
  local up=false h lib url ver
  svc_up server && mt_up && up=true
  h=$(cat "$VAR/.history.json" 2>/dev/null); [[ "$h" == \{* ]] || h='{"queue":[],"done":[]}'
  lib=$(jq -c 'del(.files)' "$VAR/library.json" 2>/dev/null); [[ "$lib" == \{* ]] || lib='null'
  url=$(env_get APP_URL); ver=$(mt_versions)
  jq -n -c --argjson up "$up" --argjson h "$h" --argjson lib "$lib" --argjson d "$(defaults_json)" --arg url "$url" \
     --arg dir "$(env_get_q DL_DIR)" --arg dstate "$(cat "$VAR/dlstate" 2>/dev/null)" --arg fix "$(dl_fix_text "$(cat "$VAR/dlstate" 2>/dev/null)" "$(env_get_q DL_DIR)")" \
     --arg image "$(env_get MT_IMAGE)" --arg mtv "${ver%% *}" --arg ytv "${ver#* }" --arg lan_ip "$(env_get LAN_IP)" \
     --arg qr "$(qr_for "$url/")" --arg qrs "$(qr_for "$url/dsm-share.html")" --argjson stale "$(stale_count)" \
     --argjson today "$(date -d "$(date +%Y-%m-%d) 00:00" +%s 2>/dev/null || echo 0)" '
    {up: $up, url: $url, share_url: ($url + "/dsm-share.html"), qr: $qr, qr_share: $qrs, image: $image, lan_ip: $lan_ip,
     metube_version: $mtv, ytdlp_version: (if $ytv == $mtv then "" else $ytv end), stale_failures: $stale,
     folder: {path: $dir, state: (if $dstate == "" then "unknown" else $dstate end), fix: $fix},
     defaults: $d, queue: $h.queue, done: $h.done, library: $lib,
     counts: {queued: ([$h.queue[] | select(.status != "downloading" and .status != "preparing")] | length),
              downloading: ([$h.queue[] | select(.status == "downloading" or .status == "preparing")] | length),
              finished_today: ([$h.done[] | select(.status == "finished" and .at >= $today)] | length),
              failed: ([$h.done[] | select(.status == "error")] | length),
              finished: ([$h.done[] | select(.status == "finished")] | length)}}' 2>/dev/null || echo '{"up": false}'
}
app_logs() { :; }
app_storage() {   # the download folder, beside the state volume
  jq -c '{downloads_mb: ((.bytes // 0) / 1048576 | floor), files: (.count // 0), free_mb: ((.disk_free // 0) / 1048576 | floor)}' "$VAR/library.json" 2>/dev/null || echo '{}'
}
app_restore() {   # dir — MeTube's state volume as the core backs it up, and the notification marks started afresh
  [[ -s "$1/state.tar.gz" ]] || { MSG="That backup has no MeTube state."; return 1; }
  in_volume state rw -- "find /vol -mindepth 1 -delete && tar -C /vol --strip-components=1 -xzf - && chown -R $HOST_UID:$HOST_GID /vol" < "$1/state.tar.gz" 2>>"$LOG" || { MSG="MeTube's state didn't go back; MeTube is left stopped."; return 1; }
  rm -f "$VAR/.seen.json" "$VAR/.history.json" "$VAR/.mt-version"
}
app_report() {
  local h; h=$(cat "$VAR/.history.json" 2>/dev/null)
  echo "== MeTube"; echo "versions: $(mt_versions) (image $(env_get MT_IMAGE))"
  echo "download folder: state $(cat "$VAR/dlstate" 2>/dev/null) (in shared folder $(basename "$(share_root "$(env_get_q DL_DIR)")"))"
  echo "defaults: $(defaults_json)"
  echo "downloads: $(jq -c '{queue: (.queue | length), done: (.done | length), failed: ([.done[] | select(.status == "error")] | length)}' <<< "$h" 2>/dev/null)"
  echo "recent failure reasons:"; jq -r '[.done[] | select(.status == "error") | .msg[:160]] | .[:10][]' <<< "$h" 2>/dev/null | sed 's/^/    /'
  echo "library: $(jq -c 'del(.files)' "$VAR/library.json" 2>/dev/null)"
  :
}

# ------------------------------------------------------------ updates (the core's two, for a pinned image on ghcr.io)
# The core compares Docker Hub digests of one tag and prunes images host-wide. MeTube is pinned on ghcr.io, so
# "newer" is a newer MeTube release (from GitHub, checked against ghcr.io), and updating moves the tag — after a
# backup, and removing only the old MeTube image, by name. Every MeTube release brings a current yt-dlp.
check_image_update() {
  local img cur latest token code newer=false ytl
  img=$(env_get MT_IMAGE); cur=${img##*:}
  ytl=$(curl -fsS --max-time 15 https://api.github.com/repos/yt-dlp/yt-dlp/releases/latest 2>/dev/null | jq -r '.tag_name // ""' 2>/dev/null | tr -cd '0-9.')
  [[ "$img" == "$MT_REPO:"* ]] || { IMAGE_UPDATE=$(jq -n -c --arg y "$ytl" '{error: "a custom image is in use, so it isn'"'"'t checked", ytdlp_latest: $y}'); return 0; }
  latest=$(curl -fsS --max-time 15 https://api.github.com/repos/alexta69/metube/releases/latest 2>/dev/null | jq -r '.tag_name // ""' 2>/dev/null | tr -cd '0-9.')
  [[ "$latest" =~ $MT_VER_RE ]] || { IMAGE_UPDATE=$(jq -n -c --arg y "$ytl" '{error: "GitHub could not be reached", ytdlp_latest: $y}'); return 0; }
  if version_gt "$latest" "$cur"; then
    token=$(curl -fsS --max-time 15 "https://ghcr.io/token?scope=repository:alexta69/metube:pull" 2>/dev/null | jq -r '.token // ""' 2>/dev/null)
    code=$(printf 'header = "Authorization: Bearer %s"\n' "$token" | curl -s -K - -o /dev/null -I -w '%{http_code}' --max-time 15 \
      -H "Accept: application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.list.v2+json, application/vnd.docker.distribution.manifest.v2+json" \
      "https://ghcr.io/v2/alexta69/metube/manifests/$latest" 2>/dev/null)
    [[ "$code" == 200 ]] && newer=true   # a release whose image isn't published yet waits for the next look
  fi
  IMAGE_UPDATE=$(jq -n -c --arg img "$img" --arg cur "$cur" --arg latest "$latest" --argjson newer "$newer" --arg y "$ytl" --argjson at "$(now)" \
    '{checked: $at, image: $img, current: $cur, latest: $latest, available: $newer, ytdlp_latest: $y}')
}
update_app() {
  local old to; old=$(env_get MT_IMAGE); to=$(jq -r '.latest // ""' <<< "$IMAGE_UPDATE" 2>/dev/null)
  say "updating $PKG_TITLE — first, a backup"
  make_backup pre-update || { MSG="Couldn't back up first, so $PKG_TITLE wasn't updated."; return 1; }
  record_backup true "$MADE"
  [[ "$to" =~ $MT_VER_RE && "$old" == "$MT_REPO:"* ]] && version_gt "$to" "${old##*:}" && { env_set MT_IMAGE "$MT_REPO:$to"; say "MeTube ${old##*:} → $to"; }
  say "pulling $(env_get MT_IMAGE)"; compose pull 2>&1 | grep -vE '^\s*$' | tail -n 20 | tee -a "$LOG" >/dev/null || true
  if ! docker image inspect "$(env_get MT_IMAGE)" >/dev/null 2>&1 || ! compose up -d --remove-orphans 2>&1 | tee -a "$LOG" >/dev/null; then
    env_set MT_IMAGE "$old"; compose up -d >> "$LOG" 2>&1 || true; MSG="The new MeTube didn't download or start, so the version from before is back — see the log."; return 1; fi
  app_after_up
  wait_ready 900 || { MSG="$PKG_TITLE was updated but hasn't answered yet — see the log."; return 1; }
  [[ "$(env_get MT_IMAGE)" != "$old" ]] && { docker image rm "$old" >> "$LOG" 2>&1 && say "removed the old image $old"; }
  rm -f "$VAR/.stale"
  check_image_update
  MSG="$PKG_TITLE is updated to $(app_version), with yt-dlp $(ytdlp_version). The state from before is in $MADE."
}

# ------------------------------------------------------------ actions
recreate() {   # after an .env change: MeTube made again, then ready
  compose up -d --remove-orphans >> "$LOG" 2>&1 || { MSG="$PKG_TITLE didn't start with the change — see the log."; return 1; }
  wait_ready 300 || { MSG="$PKG_TITLE hasn't come back yet — see the log."; return 1; }
}
need_mt() { mt_up || { MSG="MeTube isn't answering yet — try again in a minute."; return 1; }; }
need_folder() { [[ "$(cat "$VAR/dlstate" 2>/dev/null)" == ok ]] || { MSG="Downloads can't be saved yet: $(dl_fix_text "$(cat "$VAR/dlstate" 2>/dev/null)" "$(env_get_q DL_DIR)")"; return 1; }; }
playlist_url() {   # url mode → the url MeTube should get: a YouTube video in a playlist becomes the playlist when "all" was asked
  local u=$1
  if [[ "$2" == all && "$u" =~ ^https?://(www\.|m\.|music\.)?youtube\.com/watch\?.*[?\&]list=([A-Za-z0-9_-]+) ]]; then echo "https://www.youtube.com/playlist?list=${BASH_REMATCH[2]}"; return; fi
  if [[ "$2" == all && "$u" =~ ^https?://(www\.|m\.|music\.)?youtube\.com/watch\?list=([A-Za-z0-9_-]+) ]]; then echo "https://www.youtube.com/playlist?list=${BASH_REMATCH[2]}"; return; fi
  echo "$u"
}
add_one() {   # url → 0 when MeTube took it; the reason in ADD_WHY
  local body out tags presets='[]'
  if [[ "$DL_KIND" == audio ]]; then
    tags=$([[ "$(env_get EMBED_THUMB)" == 1 ]] && echo with_cover || { [[ "$(env_get EMBED_META)" == 1 ]] && echo no_cover || echo none; })
    body=$(jq -n -c --arg u "$1" --arg f "$DL_AFORMAT" --arg folder "$FOLDER" --argjson lim "$LIMIT" --arg tags "$tags" \
      '{url: $u, download_type: "audio", codec: "auto", format: $f, quality: "best", folder: $folder, playlist_item_limit: $lim, auto_start: true, audio_tags: $tags}')
  else
    [[ "$DL_VFORMAT" == mp4 && "$(env_get EMBED_THUMB)" == 1 ]] && presets='["dsm-cover"]'
    body=$(jq -n -c --arg u "$1" --arg f "$DL_VFORMAT" --arg q "$DL_QUALITY" --arg folder "$FOLDER" --argjson lim "$LIMIT" --argjson p "$presets" \
      '{url: $u, download_type: "video", codec: "auto", format: $f, quality: $q, folder: $folder, playlist_item_limit: $lim, auto_start: true, ytdl_options_presets: $p}')
  fi
  out=$(MT_TIMEOUT=180 mt_api POST add "$body") && return 0
  ADD_WHY=$(mt_why "$out"); [[ -n "$ADD_WHY" ]] || ADD_WHY="MeTube didn't answer"
  [[ "$ADD_WHY" =~ [Rr]efusing.*internal ]] && ADD_WHY="$ADD_WHY (an address on your own network: allow it on the Defaults tab)"
  return 1
}
app_act() {   # action (request vars are set)
  local u urls=() ok=0 bad=() out key where p paths=() raw
  case "$1" in dlfolder|notifyset|dsmtest|defaults) ;; *) need_mt || return 1 ;; esac
  case "$1" in
    dladd)
      need_folder || return 1
      raw=$(unb64 "${URLS_B64:-}") || { MSG="Those links didn't arrive in one piece."; return 1; }
      while IFS= read -r u; do u=${u%$'\r'}; [[ -z "$u" ]] && continue
        url_ok "$u" || { MSG="Not a web address: $(printf '%s' "$u" | tr -d '\000-\037' | cut -c1-80)"; return 1; }
        urls+=("$u"); done <<< "$raw"
      (( ${#urls[@]} >= 1 && ${#urls[@]} <= 20 )) || { MSG="One to twenty links at a time."; return 1; }
      [[ -n "${DL_KIND:-}" ]] || DL_KIND=$(env_get DEF_KIND)
      DL_QUALITY=${DL_QUALITY:-$(env_get DEF_QUALITY)}; DL_VFORMAT=${DL_VFORMAT:-$(env_get DEF_VFORMAT)}; DL_AFORMAT=${DL_AFORMAT:-$(env_get DEF_AFORMAT)}
      FOLDER=""; if [[ -n "${DL_FOLDER_B64:-}" ]]; then FOLDER=$(unb64 "$DL_FOLDER_B64") && folder_ok "$FOLDER" || { MSG="A subfolder is up to four names separated by /, without dots at the start."; return 1; }; fi
      LIMIT=$(( 10#${DL_PLLIMIT:-50} )); local mode=${DL_PLAYLIST:-single}
      for u in "${urls[@]}"; do
        if add_one "$(playlist_url "$u" "$mode")"; then ok=$(( ok + 1 )); else bad+=("$(printf '%s' "$u" | cut -c1-60): $ADD_WHY"); fi
      done
      say "added $ok of ${#urls[@]} link(s) ($DL_KIND$([[ "$DL_KIND" == audio ]] && echo " $DL_AFORMAT" || echo " $DL_VFORMAT $DL_QUALITY")${FOLDER:+, into $FOLDER})"
      watch_downloads
      if (( ${#bad[@]} == 0 )); then MSG="Added $([[ $ok == 1 ]] && echo "the link" || echo "all $ok links") — follow $([[ $ok == 1 ]] && echo it || echo them) on the Downloads tab."
      else MSG="Added $ok of ${#urls[@]}. $(printf '%s ' "${bad[@]:0:3}")"; (( ok > 0 )) || return 1; fi ;;
    dlretry)
      key=$(unb64 "${DL_ID_B64:-}") && url_ok "$key" || { MSG="Pick a download."; return 1; }
      out=$(MT_TIMEOUT=180 mt_api POST retry "$(jq -n -c --arg id "$key" '{id: $id}')") || { MSG="MeTube didn't retry it: $(mt_why "$out")"; watch_downloads; return 1; }
      mt_api POST delete "$(jq -n -c --arg id "$key" '{ids: [$id], where: "done"}')" >/dev/null || true
      watch_downloads; MSG="Trying it again — follow it on the Downloads tab." ;;
    dlremove)
      key=$(unb64 "${DL_ID_B64:-}") && url_ok "$key" || { MSG="Pick a download."; return 1; }
      where=$(jq -r --arg k "$key" 'if ([.queue[] | select(.key == $k)] | length) > 0 then "queue" elif ([.done[] | select(.key == $k)] | length) > 0 then "done" else "" end' <<< "$(history_json)" 2>/dev/null)
      [[ -n "$where" ]] || { MSG="That download isn't in MeTube's list any more."; return 1; }
      mt_api POST delete "$(jq -n -c --arg id "$key" --arg w "$where" --argjson f "$([[ "${DL_DELFILE:-0}" == 1 && "$where" == done ]] && echo true || echo false)" '{ids: [$id], where: $w, delete_files: $f}')" >/dev/null \
        || { MSG="MeTube didn't remove it."; return 1; }
      watch_downloads; [[ "${DL_DELFILE:-0}" == 1 ]] && library_scan
      MSG=$([[ "$where" == queue ]] && echo "Stopped and removed from the queue." || { [[ "${DL_DELFILE:-0}" == 1 ]] && echo "Removed from the list, and its file deleted." || echo "Removed from the list; the file stays in the download folder."; }) ;;
    dlclear)
      local ids; ids=$(jq -c --arg s "$([[ "$DL_WHICH" == failed ]] && echo error || echo finished)" '[.done[] | select(.status == $s) | .key]' <<< "$(history_json)" 2>/dev/null)
      [[ "$(jq length <<< "${ids:-[]}")" -gt 0 ]] || { MSG="There's nothing $DL_WHICH to clear."; return 0; }
      mt_api POST delete "$(jq -n -c --argjson ids "$ids" '{ids: $ids, where: "done", delete_files: false}')" >/dev/null || { MSG="MeTube didn't clear the list."; return 1; }
      watch_downloads; MSG="Cleared $(jq length <<< "$ids") $DL_WHICH download$([[ "$(jq length <<< "$ids")" == 1 ]] || echo s) from the list; the files stay." ;;
    dlstart)
      key=$(unb64 "${DL_ID_B64:-}") && url_ok "$key" || { MSG="Pick a download."; return 1; }
      mt_api POST start "$(jq -n -c --arg id "$key" '{ids: [$id]}')" >/dev/null || { MSG="MeTube didn't start it."; return 1; }
      watch_downloads; MSG="Started." ;;
    libscan) library_scan; dl_prepare && recreate; MSG="The download folder was looked at again$([[ "$(cat "$VAR/dlstate")" == ok ]] && echo "." || echo ": $(dl_fix_text "$(cat "$VAR/dlstate")" "$(env_get_q DL_DIR)")")" ;;
    libdelete)
      raw=$(unb64 "${PATHS_B64:-}") || { MSG="Pick files to delete."; return 1; }
      while IFS= read -r p; do [[ -z "$p" ]] && continue; rel_ok "$p" || { MSG="That isn't a file in the download folder."; return 1; }; paths+=("$p"); done <<< "$raw"
      (( ${#paths[@]} >= 1 && ${#paths[@]} <= 100 )) || { MSG="Pick one to a hundred files."; return 1; }
      lib_delete "${paths[@]}" || return 1 ;;
    libclean)
      env_set CLEAN_DAYS "$(( 10#${CLEAN_DAYS:-0} ))"
      if (( 10#${CLEAN_DAYS:-0} > 0 )); then CLEANED=0; clean_old; MSG="Files older than $(( 10#$CLEAN_DAYS )) days are removed once a day; $CLEANED went just now."
      else MSG="The automatic clean-up is off; nothing is removed by itself."; fi ;;
    defaults)
      [[ -n "${DL_KIND:-}" && -n "${DL_QUALITY:-}" && -n "${DL_VFORMAT:-}" && -n "${DL_AFORMAT:-}" && -n "${OUT_TPL:-}" && -n "${SUB_MODE:-}" && -n "${SUB_LANGS:-}" \
         && -n "${SUB_AUTO:-}" && -n "${EMBED_THUMB:-}" && -n "${EMBED_META:-}" && -n "${MAX_DL:-}" && -n "${LAN_URLS:-}" ]] || { MSG="Every default needs a value."; return 1; }
      local before after; before=$(env_get YTDL_OPTS)$(env_get OUTPUT_TEMPLATE)$(env_get MT_MAX_DL)$(env_get MT_LAN)
      env_set DEF_KIND "$DL_KIND"; env_set DEF_QUALITY "$DL_QUALITY"; env_set DEF_VFORMAT "$DL_VFORMAT"; env_set DEF_AFORMAT "$DL_AFORMAT"
      env_set OUT_TPL "$OUT_TPL"; env_set SUB_MODE "$SUB_MODE"; env_set SUB_LANGS "$SUB_LANGS"; env_set SUB_AUTO "$SUB_AUTO"
      env_set EMBED_THUMB "$EMBED_THUMB"; env_set EMBED_META "$EMBED_META"; env_set MT_MAX_DL "$MAX_DL"; env_set MT_LAN "$([[ "$LAN_URLS" == 1 ]] && echo true || echo false)"
      apply_defaults_env; write_share_page || true
      after=$(env_get YTDL_OPTS)$(env_get OUTPUT_TEMPLATE)$(env_get MT_MAX_DL)$(env_get MT_LAN)
      say "defaults: $DL_KIND, video $DL_VFORMAT $DL_QUALITY, audio $DL_AFORMAT, names $OUT_TPL, subtitles $SUB_MODE ($SUB_LANGS, automatic $(on_off "$SUB_AUTO")), cover $(on_off "$EMBED_THUMB"), metadata $(on_off "$EMBED_META"), $MAX_DL at a time, own network $(on_off "$LAN_URLS")"
      if [[ "$before" != "$after" ]]; then recreate || return 1; MSG="Saved; MeTube restarted with them (downloads under way pick up where they were)."
      else MSG="Saved."; fi ;;
    dlfolder)
      p=$(unb64 "${DL_DIR_B64:-}") && path_ok "$p" || { MSG="A folder inside a shared folder, like /volume1/Downloads/MeTube."; return 1; }
      env_set_q DL_DIR "$p"; say "download folder: $p"
      dl_prepare; recreate || return 1; rm -f "$VAR/library.json"; library_scan
      if [[ "$(cat "$VAR/dlstate")" == ok ]]; then MSG="Downloads now go to $p."
      else MSG="Saved, but $(dl_fix_text "$(cat "$VAR/dlstate")" "$p")"; return 1; fi ;;
    notifyset)
      env_set NOTIFY_DONE "$NOTIFY_DONE"; env_set NOTIFY_FAIL "$NOTIFY_FAIL"
      MSG="DSM tells you about $(case "$NOTIFY_DONE$NOTIFY_FAIL" in 11) echo "every finished and failed download" ;; 01) echo "failed downloads" ;; 10) echo "finished downloads" ;; *) echo "nothing (yt-dlp going out of date still comes)" ;; esac)." ;;
    dsmtest)
      notify dsmtest 0
      grep -q "told DSM: dsmtest" <<< "$(tail -n 3 "$LOG")" && MSG="A test went to DSM's notifications." || { MSG="DSM's notifications couldn't be reached — the log says why."; return 1; } ;;
    *) MSG="Unknown request."; return 1 ;;
  esac
}
folder_ok() {   # a subfolder for downloads: up to four plain names
  local f=$1 bad='[[:cntrl:]]' part
  [[ ${#f} -le 120 && ! "$f" =~ $bad && "$f" != /* && "$f" != */ && "$f" != *//* ]] || return 1
  IFS=/ read -r -a _p <<< "$f"; (( ${#_p[@]} >= 1 && ${#_p[@]} <= 4 )) || return 1
  local re="^[A-Za-z0-9 _()&,'+-][A-Za-z0-9 ._()&,'+-]*\$"
  for part in "${_p[@]}"; do [[ "$part" =~ $re && "$part" != *" " ]] || return 1; done
}
