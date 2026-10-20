# MeTube's actions, validated by the chassis CGI before they become a request file.
# Free text (links, folder names, file paths) travels base64url-encoded: the request file allows only a few characters.
# Two reads go past the setup container: the live queue straight from MeTube on this NAS (progress every
# couple of seconds) and the download folder's file list the setup container keeps.
b64u() { printf '%s' "$1" | base64 -w0 | tr '+/' '-_' | tr -d '='; }
MT_LANGS=" en de fr es it nl pt pl sv da nb fi cs hu ro el tr ru uk ar he hi ja ko zh-Hans zh-Hant id vi th "
one_of() { [[ " $2 " == *" $1 "* ]]; }
url_line_ok() { local bad='[[:space:][:cntrl:]]'; [[ "$1" =~ ^https?://[A-Za-z0-9] && ${#1} -le 1000 && ! "$1" =~ $bad ]]; }
sub_ok() {   # a subfolder for downloads: up to four plain names
  local f=$1 bad='[[:cntrl:]]' re="^[A-Za-z0-9 _()&,'+-][A-Za-z0-9 ._()&,'+-]*\$" part
  [[ ${#f} -le 120 && ! "$f" =~ $bad && "$f" != /* && "$f" != */ && "$f" != *//* ]] || return 1
  IFS=/ read -r -a _p <<< "$f"; (( ${#_p[@]} >= 1 && ${#_p[@]} <= 4 )) || return 1
  for part in "${_p[@]}"; do [[ "$part" =~ $re && "$part" != *" " ]] || return 1; done
}
dir_ok() {   # the download folder: inside a shared folder on a volume, nothing odd
  local p=$1 bad='[[:cntrl:]$"`\\]'
  [[ "$p" =~ ^/volume(USB)?[0-9]+(-[0-9]+)?/[^/@#][^/]*(/[^/]+)*$ && "$p" != *..* && "$p" != *//* && ${#p} -le 400 && ! "$p" =~ $bad ]] || return 1
  [[ "$p" =~ ^/volume(USB)?[0-9]+(-[0-9]+)?/$PKG_NAME(/|$) ]] && return 1
  [[ "$p" != */@* && "$p" != *"/#recycle"* && "$p" != *"/#snapshot"* ]]
}
rel_path_ok() { local p=$1 bad='[[:cntrl:]]'; [[ -n "$p" && ${#p} -le 400 && "$p" != /* && "$p" != */ && "$p" != *//* && ! "$p" =~ $bad && "/$p/" != */../* && "/$p/" != */./* && "/$p" != */.* ]]; }
id_param() {   # the download's key (its link) from the body → $dl_id, or error
  dl_id=$(decode "$(param id "$1")"); url_line_ok "$dl_id" || error "400 Bad Request" "Pick a download."
}
SLIM='def slim: {key: .url, url, title: (.title // ""), status: (.status // ""), percent: (.percent // null), speed: (.speed // null), eta: (.eta // null),
        size: (.size // null), filename: (.filename // null), folder: (.folder // ""), kind: (.download_type // ""), format: (.format // ""), quality: (.quality // ""),
        msg: ((.msg // .error // "") | tostring | sub("^ERROR: "; "") | .[:400]), at: (((.timestamp // 0) / 1000000000) | floor)};
      {at: now | floor, queue: ([.queue[]?, .pending[]?] | map(slim)), done: (.done // [] | map(slim) | sort_by(-.at) | .[:300])}'
app_cgi_get() {   # action query
  local port h
  case "$1" in
    live)
      port=$(jq -r '.port // ""' "$VAR/status.json" 2>/dev/null | tr -cd '0-9')
      [[ "$port" =~ ^[0-9]{2,5}$ ]] || error "503 Service Unavailable" "MeTube's port isn't known yet."
      h=$(curl -s --max-time 4 "http://127.0.0.1:$port/history" 2>/dev/null | jq -c "$SLIM" 2>/dev/null)
      [[ "$h" == \{* ]] || error "503 Service Unavailable" "MeTube isn't answering."
      reply "200 OK" application/json "$h" ;;
    files)
      [[ -f "$VAR/library.json" ]] || reply "200 OK" application/json '{"files":[]}'
      reply "200 OK" application/json "$(cat "$VAR/library.json")" ;;
  esac
}
app_cgi_post() {   # action body → sets $lines, or error
  local a=$1 body=$2 v kind q vf af folder pl lim which days paths n p u count
  case "$a" in
    libscan|dsmtest) lines="ACTION='$a'" ;;
    dladd)
      v=$(decode "$(param urls "$body")" | tr -d '\r'); count=0; u=""
      while IFS= read -r p; do p=${p#"${p%%[![:space:]]*}"}; p=${p%"${p##*[![:space:]]}"}; [[ -z "$p" ]] && continue
        url_line_ok "$p" || error "400 Bad Request" "Each line is one link starting with http:// or https:// (up to 1000 characters)."
        count=$(( count + 1 )); u+="$p"$'\n'; done <<< "$v"
      (( count >= 1 && count <= 20 )) || error "400 Bad Request" "Paste one to twenty links, one per line."
      kind=$(param kind "$body"); q=$(param quality "$body"); vf=$(param vformat "$body"); af=$(param aformat "$body"); pl=$(param playlist "$body"); lim=$(param limit "$body")
      folder=$(decode "$(param folder "$body")")
      one_of "$kind" "video audio" || error "400 Bad Request" "Video or audio."
      one_of "$q" "best 2160 1080 720 480" || error "400 Bad Request" "Pick a quality."
      one_of "$vf" "mp4 any" || error "400 Bad Request" "Pick a video format."
      one_of "$af" "mp3 m4a opus" || error "400 Bad Request" "Pick an audio format."
      one_of "$pl" "single all" || error "400 Bad Request" "Just the video, or the whole playlist."
      [[ "$lim" =~ ^[0-9]{1,3}$ ]] && (( 10#$lim >= 1 && 10#$lim <= 500 )) || error "400 Bad Request" "A playlist limit from 1 to 500."
      [[ -z "$folder" ]] || sub_ok "$folder" || error "400 Bad Request" "A subfolder is up to four names separated by /, letters, digits, spaces and - _ ( ) & , ' + ."
      lines="ACTION='dladd'
URLS_B64='$(b64u "${u%$'\n'}")'
DL_KIND='$kind'
DL_QUALITY='$q'
DL_VFORMAT='$vf'
DL_AFORMAT='$af'
DL_PLAYLIST='$pl'
DL_PLLIMIT='$(( 10#$lim ))'"
      [[ -n "$folder" ]] && lines="$lines
DL_FOLDER_B64='$(b64u "$folder")'" ;;
    dlretry|dlstart)
      id_param "$body"; lines="ACTION='$a'
DL_ID_B64='$(b64u "$dl_id")'" ;;
    dlremove)
      id_param "$body"; v=$(param delfile "$body"); [[ "$v" =~ ^[01]$ ]] || error "400 Bad Request" "Keep the file, or delete it."
      lines="ACTION='dlremove'
DL_ID_B64='$(b64u "$dl_id")'
DL_DELFILE='$v'" ;;
    dlclear)
      which=$(param which "$body"); one_of "$which" "finished failed" || error "400 Bad Request" "Finished or failed."
      lines="ACTION='dlclear'
DL_WHICH='$which'" ;;
    libdelete)
      v=$(decode "$(param paths "$body")" | tr -d '\r'); n=0
      while IFS= read -r p; do [[ -z "$p" ]] && continue; rel_path_ok "$p" || error "400 Bad Request" "That isn't a file in the download folder."; n=$(( n + 1 )); done <<< "$v"
      (( n >= 1 && n <= 100 )) || error "400 Bad Request" "Pick one to a hundred files."
      lines="ACTION='libdelete'
PATHS_B64='$(b64u "$v")'" ;;
    libclean)
      days=$(param days "$body"); [[ "$days" =~ ^[0-9]{1,4}$ ]] && (( 10#$days <= 3650 )) || error "400 Bad Request" "Days from 1 to 3650, or 0 for off."
      lines="ACTION='libclean'
CLEAN_DAYS='$(( 10#$days ))'" ;;
    defaults)
      kind=$(param kind "$body"); q=$(param quality "$body"); vf=$(param vformat "$body"); af=$(param aformat "$body")
      local tpl sm sl sa et em mx lan l
      tpl=$(param tpl "$body"); sm=$(param sub_mode "$body"); sl=$(decode "$(param sub_langs "$body")"); sa=$(param sub_auto "$body")
      et=$(param thumb "$body"); em=$(param meta "$body"); mx=$(param max_dl "$body"); lan=$(param lan "$body")
      one_of "$kind" "video audio" && one_of "$q" "best 2160 1080 720 480" && one_of "$vf" "mp4 any" && one_of "$af" "mp3 m4a opus" || error "400 Bad Request" "Pick what to download by default."
      one_of "$tpl" "title title_id channel date" || error "400 Bad Request" "Pick a file name pattern."
      one_of "$sm" "off download embed" || error "400 Bad Request" "Subtitles: off, as files, or in the video."
      [[ "$sl" =~ ^[A-Za-z+-]+$ && ${#sl} -le 60 ]] || error "400 Bad Request" "Pick one to five subtitle languages."
      IFS=+ read -r -a _sl <<< "$sl"; (( ${#_sl[@]} >= 1 && ${#_sl[@]} <= 5 )) || error "400 Bad Request" "Pick one to five subtitle languages."
      for l in "${_sl[@]}"; do one_of "$l" "$MT_LANGS" || error "400 Bad Request" "Pick subtitle languages from the list."; done
      for v in "$sa" "$et" "$em" "$lan"; do [[ "$v" =~ ^[01]$ ]] || error "400 Bad Request" "A setting is on or off."; done
      [[ "$mx" =~ ^[1-5]$ ]] || error "400 Bad Request" "One to five downloads at a time."
      lines="ACTION='defaults'
DL_KIND='$kind'
DL_QUALITY='$q'
DL_VFORMAT='$vf'
DL_AFORMAT='$af'
OUT_TPL='$tpl'
SUB_MODE='$sm'
SUB_LANGS='$sl'
SUB_AUTO='$sa'
EMBED_THUMB='$et'
EMBED_META='$em'
MAX_DL='$mx'
LAN_URLS='$lan'" ;;
    dlfolder)
      v=$(decode "$(param dir "$body")"); v=${v%/}
      dir_ok "$v" || error "400 Bad Request" "A folder inside a shared folder, like /volume1/Downloads/MeTube."
      lines="ACTION='dlfolder'
DL_DIR_B64='$(b64u "$v")'" ;;
    notifyset)
      v=$(param done "$body"); p=$(param failed "$body"); [[ "$v" =~ ^[01]$ && "$p" =~ ^[01]$ ]] || error "400 Bad Request" "On or off."
      lines="ACTION='notifyset'
NOTIFY_DONE='$v'
NOTIFY_FAIL='$p'" ;;
  esac
}
