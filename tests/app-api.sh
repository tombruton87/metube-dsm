# MeTube's CGI checks (sourced by chassis/tests/test-api.sh).
U='https%3A%2F%2Fwww.youtube.com%2Fwatch%3Fv%3DaqzKEbpKQ'
ADD="kind=video&quality=1080&vformat=mp4&aformat=mp3&playlist=single&limit=50"
expect "dladd good (two links, a subfolder)" 202 "$(post "$me" dladd "action=dladd&urls=$U%0Ahttps%3A%2F%2Fvimeo.com%2F1084537&$ADD&folder=Music%2FLive+%26+more")"
request_is "dladd request (base64url)" "ACTION='dladd'
URLS_B64='aHR0cHM6Ly93d3cueW91dHViZS5jb20vd2F0Y2g_dj1hcXpLRWJwS1EKaHR0cHM6Ly92aW1lby5jb20vMTA4NDUzNw'
DL_KIND='video'
DL_QUALITY='1080'
DL_VFORMAT='mp4'
DL_AFORMAT='mp3'
DL_PLAYLIST='single'
DL_PLLIMIT='50'
DL_FOLDER_B64='TXVzaWMvTGl2ZSAmIG1vcmU'
BY='$me'"
expect "dladd javascript: refused" 400 "$(post "$me" dladd "action=dladd&urls=javascript%3Aalert(1)&$ADD")"
expect "dladd file: refused" 400 "$(post "$me" dladd "action=dladd&urls=file%3A%2F%2F%2Fetc%2Fpasswd&$ADD")"
expect "dladd injected line refused" 400 "$(post "$me" dladd "action=dladd&urls=https%3A%2F%2Fa.example%2Fx%27%0AACTION%3D%27wipe&$ADD")"
expect "dladd no links" 400 "$(post "$me" dladd "action=dladd&urls=%0A%0A&$ADD")"
expect "dladd 21 links" 400 "$(post "$me" dladd "action=dladd&urls=$(for i in $(seq 1 21); do printf 'https%%3A%%2F%%2Fa.example%%2F%s%%0A' "$i"; done)&$ADD")"
expect "dladd bad quality" 400 "$(post "$me" dladd "action=dladd&urls=$U&kind=video&quality=4320&vformat=mp4&aformat=mp3&playlist=single&limit=50")"
expect "dladd bad format" 400 "$(post "$me" dladd "action=dladd&urls=$U&kind=audio&quality=best&vformat=mp4&aformat=wav&playlist=single&limit=50")"
expect "dladd folder traversal" 400 "$(post "$me" dladd "action=dladd&urls=$U&$ADD&folder=..%2F..%2Fetc")"
expect "dladd hidden folder" 400 "$(post "$me" dladd "action=dladd&urls=$U&$ADD&folder=.metube")"
expect "dladd absolute folder" 400 "$(post "$me" dladd "action=dladd&urls=$U&$ADD&folder=%2Fvolume1")"
expect "dladd limit 0" 400 "$(post "$me" dladd "action=dladd&urls=$U&kind=video&quality=best&vformat=mp4&aformat=mp3&playlist=all&limit=0")"
expect "dlretry good" 202 "$(post "$me" dlretry "action=dlretry&id=$U")"; request_is "dlretry request" "ACTION='dlretry'
DL_ID_B64='aHR0cHM6Ly93d3cueW91dHViZS5jb20vd2F0Y2g_dj1hcXpLRWJwS1E'
BY='$me'"
expect "dlretry bad id" 400 "$(post "$me" dlretry 'action=dlretry&id=%24(id)')"
expect "dlremove good" 202 "$(post "$me" dlremove "action=dlremove&id=$U&delfile=1")"; rm -f "$CHASSIS_VAR/request"
expect "dlremove bad delfile" 400 "$(post "$me" dlremove "action=dlremove&id=$U&delfile=yes")"
expect "dlclear good" 202 "$(post "$me" dlclear 'action=dlclear&which=failed')"; rm -f "$CHASSIS_VAR/request"
expect "dlclear bad" 400 "$(post "$me" dlclear 'action=dlclear&which=all')"
expect "libdelete good" 202 "$(post "$me" libdelete 'action=libdelete&paths=Big+Buck+Bunny.mp4%0AMusic%2FSintel+%28Trailer%29.mp3')"; request_is "libdelete request" "ACTION='libdelete'
PATHS_B64='QmlnIEJ1Y2sgQnVubnkubXA0Ck11c2ljL1NpbnRlbCAoVHJhaWxlcikubXAz'
BY='$me'"
expect "libdelete traversal" 400 "$(post "$me" libdelete 'action=libdelete&paths=..%2F..%2Fetc%2Fshadow')"
expect "libdelete absolute" 400 "$(post "$me" libdelete 'action=libdelete&paths=%2Fetc%2Fshadow')"
expect "libdelete hidden" 400 "$(post "$me" libdelete 'action=libdelete&paths=.incomplete%2Fx.part')"
expect "libclean good" 202 "$(post "$me" libclean 'action=libclean&days=30')"; rm -f "$CHASSIS_VAR/request"
expect "libclean bad" 400 "$(post "$me" libclean 'action=libclean&days=-1')"
DEF="kind=audio&quality=720&vformat=any&aformat=opus&tpl=title_id&sub_mode=embed&sub_auto=1&thumb=1&meta=0&max_dl=2&lan=1"
expect "defaults good" 202 "$(post "$me" defaults "action=defaults&$DEF&sub_langs=en%2Bde%2Bzh-Hans")"; request_is "defaults request" "ACTION='defaults'
DL_KIND='audio'
DL_QUALITY='720'
DL_VFORMAT='any'
DL_AFORMAT='opus'
OUT_TPL='title_id'
SUB_MODE='embed'
SUB_LANGS='en+de+zh-Hans'
SUB_AUTO='1'
EMBED_THUMB='1'
EMBED_META='0'
MAX_DL='2'
LAN_URLS='1'
BY='$me'"
expect "defaults unknown language" 400 "$(post "$me" defaults "action=defaults&$DEF&sub_langs=en%2Bxx")"
expect "defaults six languages" 400 "$(post "$me" defaults "action=defaults&$DEF&sub_langs=en%2Bde%2Bfr%2Bes%2Bit%2Bnl")"
expect "defaults free-text template refused" 400 "$(post "$me" defaults "action=defaults&${DEF/tpl=title_id/tpl=%25(id)s}&sub_langs=en")"
expect "defaults max 6" 400 "$(post "$me" defaults "action=defaults&${DEF/max_dl=2/max_dl=6}&sub_langs=en")"
expect "dlfolder good" 202 "$(post "$me" dlfolder 'action=dlfolder&dir=%2Fvolume1%2FDownloads%2FMeTube')"; request_is "dlfolder request" "ACTION='dlfolder'
DL_DIR_B64='L3ZvbHVtZTEvRG93bmxvYWRzL01lVHViZQ'
BY='$me'"
expect "dlfolder outside a volume" 400 "$(post "$me" dlfolder 'action=dlfolder&dir=%2Fetc')"
expect "dlfolder DSM's own" 400 "$(post "$me" dlfolder 'action=dlfolder&dir=%2Fvolume1%2F%40docker')"
expect "dlfolder the package's share" 400 "$(post "$me" dlfolder 'action=dlfolder&dir=%2Fvolume1%2Fmetube%2Fx')"
expect "dlfolder traversal" 400 "$(post "$me" dlfolder 'action=dlfolder&dir=%2Fvolume1%2Fa%2F..%2F..%2Fetc')"
expect "notifyset good" 202 "$(post "$me" notifyset 'action=notifyset&done=1&failed=0')"; rm -f "$CHASSIS_VAR/request"
expect "notifyset bad" 400 "$(post "$me" notifyset 'action=notifyset&done=2&failed=0')"
expect "files (none yet)" 200 "$(get "$me" 'action=files')"
expect "files viewer → 403" 403 "$(CHASSIS_ADMINS=no-such-group get "$me" 'action=files')"
expect "live without a port → 503" 503 "$(get "$me" 'action=live')"
