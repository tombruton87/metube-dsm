# MeTube's steps for the chassis harness (chassis/tests/e2e.sh <appdir> act), in parts (tests/e2e-part.sh N)
# so each run stays short. Nothing here needs YouTube: a throwaway web server on MeTube's own Docker network
# serves a generated test clip (and a page with it, and a slow copy to watch progress on), and MeTube
# downloads them with yt-dlp's generic extractor. Shared folders are directories under $E2E/shares (TEST_SHARES).
SHARES=$E2E/shares; WEB=metube-e2e-web; WEBDIR=$E2E/web; FROM_IMAGE=ghcr.io/alexta69/metube:2026.10.09
DLDIR=$SHARES/Downloads/MeTube; W=http://$WEB:8000
b64u() { printf '%s' "$1" | base64 -w0 | tr '+/' '-_' | tr -d '='; }
app_e2e_answers() {   # a fresh start: the test's shared folders and the web server's files from scratch
  docker rm -f "$WEB" >/dev/null 2>&1; docker run --rm -v "$E2E:/e" alpine rm -rf /e/shares /e/web >/dev/null 2>&1
  mkdir -p "$SHARES/Downloads" "$WEBDIR/slow"
  # A shared folder the package's user may read but not write: root's, mode 755.
  docker run --rm -v "$SHARES:/s" alpine sh -c 'mkdir -p /s/Locked && chown 0:0 /s/Locked && chmod 755 /s/Locked' >/dev/null
  docker image inspect "$FROM_IMAGE" >/dev/null 2>&1 || docker pull -q "$FROM_IMAGE" >/dev/null
  docker run --rm --user "$(id -u):$(id -g)" -v "$WEBDIR:/w" --entrypoint sh "$FROM_IMAGE" -c '
    ffmpeg -loglevel error -f lavfi -i testsrc=duration=6:size=320x240:rate=25 -f lavfi -i sine=frequency=440:duration=6 -c:v libx264 -pix_fmt yuv420p -c:a aac -shortest /w/clip.mp4 &&
    ffmpeg -loglevel error -f lavfi -i testsrc2=duration=40:size=640x360:rate=25 -f lavfi -i sine=frequency=220:duration=40 -c:v libx264 -b:v 1500k -pix_fmt yuv420p -c:a aac -shortest /w/slow/sintel-trailer.mp4 &&
    cp /w/slow/sintel-trailer.mp4 /w/slow/elephants-dream.mp4'
  printf '<html><head><title>Big Buck Bunny</title></head><body><video src="clip.mp4" controls></video></body></html>' > "$WEBDIR/page.html"
  cat > "$WEBDIR/serve.py" <<'PY'
import http.server, os, time
class H(http.server.SimpleHTTPRequestHandler):
    def copyfile(self, src, dst):   # /slow/…: about 400 KB/s, so a download can be watched
        if not self.path.startswith("/slow/"): return super().copyfile(src, dst)
        while True:
            b = src.read(16384)
            if not b: break
            dst.write(b); time.sleep(0.04)
os.chdir("/w"); http.server.ThreadingHTTPServer(("", 8000), H).serve_forever()
PY
  printf "DL_DIR_B64='%s'\nTEST_SHARES='%s'\nFIRST_IMAGE='%s'\n" "$(b64u "$DLDIR")" "$SHARES" "$FROM_IMAGE"
}
until_true() { local i; for i in $(seq 1 "$2"); do touch "$VAR/watching"; eval "$1" >/dev/null 2>&1 && return 0; sleep 1; done; return 1; }
st() { jq -r "$1" "$VAR/status.json" 2>/dev/null; }
ok() { echo "  ok   $*"; }
bad() { echo "  FAIL $*"; FAILS=$(( FAILS + 1 )); }
check() { if eval "$2" >/dev/null 2>&1; then ok "$1"; else bad "$1"; fi; }
web_up() {   # the test web server, on MeTube's network (private addresses, like a NAS on a LAN)
  docker ps -q --filter "name=^$WEB$" | grep -q . && return 0
  docker run -d --name "$WEB" --network metube_default --user "$(id -u):$(id -g)" -v "$WEBDIR:/w:ro" python:3.12-alpine python3 /w/serve.py >/dev/null
  until_true "docker exec $WEB wget -q -O /dev/null http://127.0.0.1:8000/page.html" 20
}
add() {   # links… (one string with \n), extra request lines… → the harness's request
  local u=$1; shift
  request "ACTION='dladd'" "URLS_B64='$(b64u "$(printf "$u")")'" "DL_KIND='${KIND:-video}'" "DL_QUALITY='best'" "DL_VFORMAT='mp4'" "DL_AFORMAT='${AF:-mp3}'" "DL_PLAYLIST='single'" "DL_PLLIMIT='50'" "$@"
}
done_with() { st "[.app.done[] | select(.url == \"$1\" and .status == \"$2\")] | length > 0" | grep -qx true; }
owner_ok() { [[ "$(stat -c %u "$1" 2>/dev/null)" == "$(id -u)" ]]; }
defaults() {   # overrides as KEY=value… → a defaults request with everything else as it is now
  local -A d=([DL_KIND]=video [DL_QUALITY]=best [DL_VFORMAT]=mp4 [DL_AFORMAT]=mp3 [OUT_TPL]=title [SUB_MODE]=off [SUB_LANGS]=en [SUB_AUTO]=0 [EMBED_THUMB]=1 [EMBED_META]=1 [MAX_DL]=3 [LAN_URLS]=1)
  local kv lines=("ACTION='defaults'"); for kv in "$@"; do d[${kv%%=*}]=${kv#*=}; done
  for kv in "${!d[@]}"; do lines+=("$kv='${d[$kv]}'"); done
  request "${lines[@]}"
}
cenv() { docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' metube-server | grep "^$1=" | cut -d= -f2-; }

app_e2e_act() { [[ "${E2E_PART:-0}" == 0 ]] && return 0; FAILS=0
  log "metube, part $E2E_PART (MeTube $(st .version), yt-dlp $(st .app.ytdlp_version), folder $(st .app.folder.state))"
  case "$E2E_PART" in
  1)  # first start, the share page, the private-address guard, defaults, video and audio downloads
    check "MeTube answers; the download folder is usable" '[[ "$(st .app.up)" == true && "$(st .app.folder.state)" == ok ]]'
    check "the MeTube subfolder was made in the Downloads share, as the package's user" 'owner_ok "$DLDIR"'
    check "started from the older release ($FROM_IMAGE)" '[[ "$(st .app.image)" == "$FROM_IMAGE" ]]'
    check "yt-dlp's version is known" '[[ "$(st .app.ytdlp_version)" =~ ^20[0-9]{2}\. ]]'
    check "the share page is served by MeTube, with the defaults in it" 'curl -fsS http://127.0.0.1:$PORT/dsm-share.html | grep -q "\"vformat\":\"mp4\""'
    check "MeTube runs as the package's user" '[[ "$(docker inspect -f "{{.Config.User}}" metube-server)" == "$(id -u):$(id -g)" ]]'
    web_up || bad "the test web server didn't start"
    add "$W/page.html" >/dev/null; check "a link on the own network is refused while that's off, with the reason" 'done_with "$W/page.html" error && st ".app.done[0].msg" | grep -qiE "internal|private|refus"'
    defaults OUT_TPL=title_id MAX_DL=2 SUB_MODE=download SUB_LANGS=en+de || bad "defaults"
    check "defaults reach MeTube: template, 2 at a time, subtitles, own network" '[[ "$(cenv OUTPUT_TEMPLATE)" == "%(title)s [%(id)s].%(ext)s" && "$(cenv MAX_CONCURRENT_DOWNLOADS)" == 2 && "$(cenv ALLOW_PRIVATE_ADDRESSES)" == true ]] && cenv YTDL_OPTIONS | jq -e ".windowsfilenames and (.updatetime == false) and .writesubtitles and (.subtitleslangs == [\"en\",\"de\"])"'
    check "the window shows the defaults" '[[ "$(st .app.defaults.tpl)" == title_id && "$(st .app.defaults.max_dl)" == 2 ]]'
    request "ACTION='dlretry'" "DL_ID_B64='$(b64u "$W/page.html")'" || bad "retry of the refused link"
    until_true 'done_with "$W/page.html" finished' 60 && ok "retried now that it's allowed: finished" || bad "retry didn't finish"
    check "the video landed in the share, named by the template, owned by the package's user" 'f=$(ls "$DLDIR"/Big\ Buck\ Bunny*\[*\].mp4 | head -1) && owner_ok "$f"'
    check "the failed entry was replaced by the retry (no failed left)" '[[ "$(st "[.app.done[] | select(.status == \"error\")] | length")" == 0 ]]'
    KIND=audio AF=mp3 add "$W/clip.mp4" "DL_FOLDER_B64='$(b64u "Music/Test clips")'" || bad "audio add"
    until_true 'done_with "$W/clip.mp4" finished' 90 && ok "audio only: finished" || bad "audio didn't finish"
    check "audio converted to MP3 in the subfolder, owned by the package's user" 'f=$(ls "$DLDIR/Music/Test clips/"*.mp3 | head -1) && owner_ok "$f" && file "$f" | grep -qiE "audio|MPEG"'
    check "no unfinished files left behind" '[[ -z "$(find "$DLDIR/.incomplete" -type f 2>/dev/null)" ]]'
    ;;
  2)  # progress, waiting, stop; a bad link with its reason; retry once it's fixed; notifications
    web_up || bad "the test web server didn't start"
    defaults MAX_DL=1 || bad "one at a time"
    add "$W/slow/sintel-trailer.mp4\n$W/slow/elephants-dream.mp4" || bad "two slow links"
    until_true '[[ "$(st "[.app.queue[] | select(.status == \"downloading\" and (.percent // 0) > 0)] | length")" == 1 ]]' 60 \
      && ok "one downloading with progress ($(st '.app.queue[] | select(.status == "downloading") | "\(.percent|floor)%, \(.speed|floor) B/s, eta \(.eta)"'))" || bad "no progress seen"
    check "the other waits for a free slot" '[[ "$(st "[.app.queue[] | select(.status != \"downloading\" and .status != \"preparing\")] | length")" == 1 ]]'
    check "the overview counts: 1 downloading, 1 in the queue" '[[ "$(st .app.counts.downloading)" == 1 && "$(st .app.counts.queued)" == 1 ]]'
    local first; first=$(st '.app.queue[] | select(.status == "downloading") | .url')
    request "ACTION='dlremove'" "DL_ID_B64='$(b64u "$first")'" "DL_DELFILE='0'" || bad "stop"
    until_true '[[ "$(st "[.app.queue[] | select(.url == \"$first\")] | length")" == 0 ]]' 30 && ok "stopped and gone from the queue" || bad "stop didn't take"
    until_true '[[ "$(st "[.app.done[] | select(.status == \"finished\" and (.url | test(\"/slow/\")))] | length")" -ge 1 ]]' 120 && ok "the waiting one then finished" || bad "the second didn't finish"
    add "$W/missing.html" && bad "a missing page was taken" || ok "a missing page fails at once"
    check "…with the plain reason in the list (404)" 'st "[.app.done[] | select(.url == \"$W/missing.html\" and .status == \"error\") | .msg] | first" | grep -q 404'
    check "…and a DSM notification was attempted for it" 'grep -qE "DSM notification \(failed\)|told DSM: failed" "$VAR/package.log"'
    request "ACTION='dlretry'" "DL_ID_B64='$(b64u "$W/missing.html")'" && bad "retry of a still-missing page succeeded" || ok "retry while still missing fails, with the reason"
    docker run --rm -v "$WEBDIR:/w" alpine sh -c 'cp /w/page.html /w/missing.html && sed -i "s/Big Buck Bunny/Caminandes/" /w/missing.html'
    request "ACTION='dlretry'" "DL_ID_B64='$(b64u "$W/missing.html")'" || bad "retry after the fix"
    until_true 'done_with "$W/missing.html" finished' 60 && ok "retried once the page is there: finished" || bad "retry after the fix didn't finish"
    request "ACTION='notifyset'" "NOTIFY_DONE='1'" "NOTIFY_FAIL='1'" || bad "notifyset"
    check "notification choices kept" '[[ "$(st .app.defaults.notify_done)" == true ]]'
    defaults MAX_DL=3 >/dev/null
    ;;
  3)  # library: list, delete, path guard, clean-up; clear and remove with the file; the folder's permission and absence
    request "ACTION='libscan'" || bad "libscan"
    check "the library lists the files with totals and free space" '[[ "$(st .app.library.count)" -ge 4 && "$(st .app.library.bytes)" -gt 0 && "$(st .app.library.disk_free)" -gt 0 ]]'
    check "the file list is there for the window, owned by the package's user" 'jq -e ".files | length >= 4" "$VAR/library.json" && owner_ok "$VAR/library.json"'
    local victim; victim=$(jq -r '.files[] | select(.p | endswith(".mp3")) | .p' "$VAR/library.json" | head -1)
    request "ACTION='libdelete'" "PATHS_B64='$(b64u "$victim")'" || bad "libdelete"
    check "deleted from the share: $victim" '[[ ! -e "$DLDIR/$victim" ]]'
    check "…and its folder, left empty, went too" '[[ ! -d "$DLDIR/Music" ]]'
    touch "$SHARES/Downloads/outside.txt"
    request "ACTION='libdelete'" "PATHS_B64='$(b64u "../outside.txt")'" && bad "a path outside the folder was taken" || ok "a path outside the download folder is refused"
    check "…and the file outside is untouched" '[[ -e "$SHARES/Downloads/outside.txt" ]]'
    docker run --rm --user "$(id -u):$(id -g)" -v "$DLDIR:/d" alpine sh -c 'mkdir -p /d/Old && echo x > /d/Old/ancient.mp4 && touch -d "2026-08-01 12:00:00" /d/Old/ancient.mp4'
    request "ACTION='libclean'" "CLEAN_DAYS='30'" || bad "libclean"
    check "clean-up removed the file older than 30 days and its empty folder" '[[ ! -e "$DLDIR/Old" ]]'
    check "…and kept the new ones" '[[ -n "$(ls "$DLDIR"/*.mp4 2>/dev/null)" ]]'
    request "ACTION='libclean'" "CLEAN_DAYS='0'" || bad "clean-up off"
    local fin; fin=$(st '[.app.done[] | select(.status == "finished" and (.filename // "" | length) > 0)] | first | .url'); local file; file=$(st "[.app.done[] | select(.url == \"$fin\")] | first | .filename")
    request "ACTION='dlremove'" "DL_ID_B64='$(b64u "$fin")'" "DL_DELFILE='1'" || bad "remove with its file"
    check "removed from the list and its file deleted ($file)" '[[ ! -e "$DLDIR/$file" ]] && [[ "$(st "[.app.done[] | select(.url == \"$fin\")] | length")" == 0 ]]'
    request "ACTION='dlclear'" "DL_WHICH='finished'" || bad "clear finished"
    check "finished cleared; the files stay" '[[ "$(st .app.counts.finished)" == 0 && -n "$(ls "$DLDIR"/*.mp4 2>/dev/null)" ]]'
    request "ACTION='dlfolder'" "DL_DIR_B64='$(b64u "$SHARES/Locked/MeTube")'" && bad "a folder it can't write was taken" || ok "a shared folder it may not write in: refused with the fix"
    check "…the state says so, with DSM's steps" '[[ "$(st .app.folder.state)" =~ ^(readonly|noaccess)$ ]] && st .app.folder.fix | grep -q "System internal user"'
    check "…MeTube still runs" '[[ "$(st .app.up)" == true ]]'
    request "ACTION='dlfolder'" "DL_DIR_B64='$(b64u "$SHARES/Nowhere/MeTube")'" && bad "a missing shared folder was taken" || ok "a shared folder that isn't there: refused"
    check "…and it wasn't created" '[[ ! -e "$SHARES/Nowhere" && "$(st .app.folder.state)" == missing ]]'
    add "$W/clip.mp4" && bad "a download was taken while the folder is missing" || ok "adding waits for a usable folder, with the reason"
    request "ACTION='dlfolder'" "DL_DIR_B64='$(b64u "$DLDIR")'" || bad "back to the Downloads folder"
    check "back: state ok, MeTube saves there again" '[[ "$(st .app.folder.state)" == ok && "$(st .app.up)" == true ]]'
    ;;
  4)  # backup and restore of MeTube's state; the update to the newest release, removing only the old image
    web_up || bad "the test web server didn't start"
    add "$W/clip.mp4" >/dev/null; until_true 'done_with "$W/clip.mp4" finished' 60 || bad "a download before the backup"
    request "ACTION='backup'" || bad "backup"
    local name; name=$(st '.backups[0].name')
    check "the backup holds MeTube's queue and history (not the media)" 'tar -xOf "$APP/backups/$name" "${name%.tar}/state.tar.gz" | tar -tzf - | grep -qE "completed|queue" && ! tar -tf "$APP/backups/$name" | grep -q "\.mp4$"'
    request "ACTION='dlclear'" "DL_WHICH='finished'" >/dev/null
    check "history cleared before the restore" '[[ "$(st .app.counts.finished)" == 0 ]]'
    request "ACTION='restore'" "BACKUP='$name'" || bad "restore"
    until_true '[[ "$(st .app.counts.finished)" -ge 1 ]]' 40 && ok "restored: the finished downloads are back" || bad "history not back after the restore"
    request "ACTION='check'" || bad "check"
    check "a newer MeTube release is found on ghcr.io ($(st .image_update.latest)), and the newest yt-dlp ($(st .image_update.ytdlp_latest))" '[[ "$(st .image_update.available)" == true && "$(st .image_update.ytdlp_latest)" =~ ^20 ]]'
    local old; old=$(st .app.image); local oldyt; oldyt=$(st .app.ytdlp_version)
    request "ACTION='updateapp'" || bad "update"
    check "updated: the image moved to the newest release" '[[ "$(st .app.image)" == "ghcr.io/alexta69/metube:$(st .image_update.latest)" && "$(st .app.image)" != "$old" ]]'
    check "MeTube answers on it, yt-dlp $oldyt → $(st .app.ytdlp_version)" '[[ "$(st .app.up)" == true && "$(st .app.ytdlp_version)" =~ ^20 ]]'
    check "the old image was removed by name, nothing else pruned" '! docker image inspect "$old" && docker image inspect python:3.12-alpine'
    check "a pre-update backup was made" 'ls "$APP"/backups/metube-*-pre-update.tar'
    check "history survived the update" '[[ "$(st .app.counts.finished)" -ge 1 ]]'
    check "nothing newer now" '[[ "$(st .image_update.available)" == false ]]'
    ;;
  esac
  echo "  part $E2E_PART: $([[ $FAILS == 0 ]] && echo "all passed" || echo "$FAILS FAILED")"; (( FAILS == 0 ))
}
