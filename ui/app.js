// MeTube's tabs on the chassis window: Downloads (live), Add, Library, Defaults, Share to MeTube, yt-dlp,
// and the overview's tiles.
(function (P) {
  "use strict";
  var $ = function (id) { return document.getElementById(id); };
  var LANGS = [["en", "English"], ["de", "German"], ["fr", "French"], ["es", "Spanish"], ["it", "Italian"], ["nl", "Dutch"], ["pt", "Portuguese"], ["pl", "Polish"],
    ["sv", "Swedish"], ["da", "Danish"], ["nb", "Norwegian"], ["fi", "Finnish"], ["cs", "Czech"], ["hu", "Hungarian"], ["ro", "Romanian"], ["el", "Greek"], ["tr", "Turkish"],
    ["ru", "Russian"], ["uk", "Ukrainian"], ["ar", "Arabic"], ["he", "Hebrew"], ["hi", "Hindi"], ["ja", "Japanese"], ["ko", "Korean"], ["zh-Hans", "Chinese (simplified)"],
    ["zh-Hant", "Chinese (traditional)"], ["id", "Indonesian"], ["vi", "Vietnamese"], ["th", "Thai"]];
  var LIVE = null, FILES = null, liveTimer = null;
  function A(st) { return (st && st.app) || {}; }
  function empty(tb, text, span) { var r = P.el("tr"), c = P.cell(text, "empty"); c.colSpan = span || 1; r.appendChild(c); tb.appendChild(r); }
  function changed(node, sig) { if (node.dataset.sig === sig) return false; node.dataset.sig = sig; return true; }
  function admin() { return P.role === "admin" && !P.busy; }
  function speed(n) { return n ? P.bytes(n) + "/s" : ""; }
  function eta(s) { if (s == null) return ""; s = Math.round(s); if (s < 60) return s + " s left"; if (s < 3600) return Math.floor(s / 60) + " min " + (s % 60) + " s left"; return Math.floor(s / 3600) + " h " + Math.floor((s % 3600) / 60) + " min left"; }
  function today(ts) { var d = new Date(), t = new Date(ts * 1000); return d.toDateString() === t.toDateString(); }
  function data(st) { var a = A(st); return LIVE && (Date.now() / 1000 - LIVE.at < 20) ? LIVE : { queue: a.queue || [], done: a.done || [] }; }
  function counts(d) {
    var c = { queued: 0, downloading: 0, today: 0, failed: 0, finished: 0 };
    d.queue.forEach(function (x) { if (x.status === "downloading" || x.status === "preparing") c.downloading++; else c.queued++; });
    d.done.forEach(function (x) { if (x.status === "error") c.failed++; else if (x.status === "finished") { c.finished++; if (today(x.at)) c.today++; } });
    return c;
  }
  function folderBox(box, st) {
    var f = A(st).folder || {}; P.clear(box);
    if (!f.state || f.state === "ok" || f.state === "unknown") return;
    var d = P.el("div", null, "fix"); d.appendChild(P.el("b", f.state === "missing" ? "The download folder isn't there" : f.state === "bad" ? "No usable download folder is set" : "MeTube can't save into the download folder"));
    d.appendChild(P.el("br")); d.appendChild(document.createTextNode((f.path ? f.path + ": " : "") + (f.fix || "")));
    box.appendChild(d);
  }
  function goto(e) { e.preventDefault(); P.showTab(this.dataset.goto); }
  document.querySelectorAll("[data-goto]").forEach(function (a) { a.onclick = goto; });
  function itemCell(x) {
    var d = P.el("div"); d.appendChild(P.el("div", x.title || x.url, "dl-title"));
    var sub = x.title && x.title !== x.url ? x.url : ""; var what = x.kind === "audio" ? "audio " + (x.format || "") : x.kind === "video" ? "video " + (x.format === "any" ? "" : (x.format || "") + " ") + (x.quality && x.quality !== "best" ? x.quality + "p" : "") : x.kind;
    d.appendChild(P.el("div", [what, sub].filter(Boolean).join(" · "), "dl-sub")); return d;
  }
  function act(action, extra, confirmText) { return P.act(action, extra, confirmText).then(function () { setTimeout(pollLive, 2500); }); }

  // ------------------------------------------------------------ Downloads
  function renderDownloads(st) {
    var a = A(st), d = data(st), c = counts(d), t = $("d-tiles");
    document.querySelectorAll(".mt-link").forEach(function (l) { l.href = (a.url || "#") + "/"; });
    folderBox($("d-folder"), st);
    P.clear(t); P.tile(t, String(c.downloading), "downloading"); P.tile(t, String(c.queued), "waiting"); P.tile(t, String(c.today), "finished today"); P.tile(t, String(c.failed), "failed");
    $("d-live").textContent = LIVE && Date.now() / 1000 - LIVE.at < 20 ? "live" : a.up === false ? "MeTube isn't answering" : "";
    var q = $("d-queue"); if (changed(q, JSON.stringify(d.queue) + P.busy + P.role)) {
      P.clear(q); if (!d.queue.length) empty(q, "Nothing downloading or waiting.", 3);
      d.queue.forEach(function (x) {
        var p = P.el("div"), bar = P.el("div", null, "prog"), i = P.el("i"), pct = x.percent != null ? Math.min(100, Math.max(0, x.percent)) : null;
        if (x.status === "downloading" && pct != null) { i.style.width = pct.toFixed(1) + "%"; bar.appendChild(i); p.appendChild(bar); p.appendChild(P.el("span", pct.toFixed(0) + "% · " + [speed(x.speed), eta(x.eta)].filter(Boolean).join(" · "), "small")); }
        else p.appendChild(P.chip(x.status === "pending" ? "waiting for Start" : x.status === "preparing" ? "preparing" : x.status === "downloading" ? "downloading" : "waiting for a free slot", x.status === "pending" ? "" : "warn"));
        var acts = P.el("span", null, "row");
        if (x.status === "pending") acts.appendChild(P.btn("Start", "primary", function () { act("dlstart", { id: x.key }); }));
        acts.appendChild(P.btn(x.status === "downloading" ? "Stop" : "Remove", "", function () { act("dlremove", { id: x.key, delfile: 0 }, x.status === "downloading" ? "Stop downloading " + (x.title || x.url) + "?" : null); }));
        P.row(q, [itemCell(x), p, P.cell(acts, "n nw")]);
      });
    }
    var fl = d.done.filter(function (x) { return x.status === "error"; }), fd = $("d-failed");
    if (changed(fd, JSON.stringify(fl) + P.busy + P.role)) {
      P.clear(fd); if (!fl.length) empty(fd, "Nothing failed.", 3);
      fl.forEach(function (x) {
        var acts = P.el("span", null, "row");
        acts.appendChild(P.btn("Retry", "primary", function () { act("dlretry", { id: x.key }); }));
        acts.appendChild(P.btn("Remove", "", function () { act("dlremove", { id: x.key, delfile: 0 }); }));
        var why = P.el("div"); why.appendChild(P.el("div", x.msg || "No reason given.", "dl-err")); why.appendChild(P.el("div", P.ago(x.at), "dl-sub"));
        P.row(fd, [itemCell(x), why, P.cell(acts, "n nw")]);
      });
    }
    $("d-clear-failed").disabled = !admin() || !fl.length;
    var fin = d.done.filter(function (x) { return x.status === "finished"; }), dd = $("d-done"), root = (a.folder || {}).path || "";
    if (changed(dd, JSON.stringify(fin) + P.busy + P.role + root)) {
      P.clear(dd); if (!fin.length) empty(dd, "Nothing finished yet.", 5);
      fin.slice(0, 200).forEach(function (x) {
        var acts = P.el("span", null, "row");
        acts.appendChild(P.btn("Remove", "", function () { act("dlremove", { id: x.key, delfile: 0 }); }));
        acts.appendChild(P.btn("Delete file", "danger", function () { act("dlremove", { id: x.key, delfile: 1 }, "Delete " + (x.filename || x.title) + " from the download folder?\n\nThe file is gone for good."); }));
        var name = P.el("div"); name.appendChild(P.el("div", x.title || x.url, "dl-title")); name.appendChild(P.el("div", x.filename || "", "dl-sub"));
        P.row(dd, [name, P.cell(x.size ? P.bytes(x.size) : "–", "n"), P.cell(root + (x.folder ? "/" + x.folder : ""), "dl-sub"), P.cell(P.when(x.at), "nw"), P.cell(acts, "n nw")]);
      });
    }
    $("d-clear-done").disabled = !admin() || !fin.length;
  }
  $("d-clear-failed").onclick = function () { act("dlclear", { which: "failed" }); };
  $("d-clear-done").onclick = function () { act("dlclear", { which: "finished" }, "Clear every finished download from the list? The files stay in the download folder."); };
  function pollLive() {
    if (P.role !== "admin" || (P.tab !== "downloads" && P.tab !== "overview")) return;
    P.api("action=live").then(function (d) { LIVE = d; if (P.S) renderNow(); }).catch(function () { LIVE = null; });
  }
  function renderNow() { var st = P.S.status || {}; if (P.tab === "downloads") renderDownloads(st); badges(st); }
  function startLive() { if (!liveTimer) { pollLive(); liveTimer = setInterval(pollLive, 2000); } }
  function stopLive() { if (liveTimer) { clearInterval(liveTimer); liveTimer = null; } }

  // ------------------------------------------------------------ Add
  function addShow() { var au = $("a-kind").value === "audio"; document.querySelectorAll(".a-video").forEach(function (x) { x.hidden = au; }); document.querySelectorAll(".a-audio").forEach(function (x) { x.hidden = !au; }); }
  $("a-kind").onchange = addShow;
  function fillAdd(st) {
    var a = A(st), df = a.defaults || {};
    folderBox($("a-folder"), st);
    if (!$("a-kind").dataset.touched && df.kind) { $("a-kind").value = df.kind; $("a-quality").value = df.quality; $("a-vformat").value = df.vformat; $("a-aformat").value = df.aformat; addShow(); }
    $("a-hint").textContent = "Into " + ((a.folder || {}).path || "the download folder") + ($("a-folder-name").value.trim() ? "/" + $("a-folder-name").value.trim() : "") + ".";
    var dl = $("a-folders"); if (FILES && changed(dl, String(FILES.at))) {
      P.clear(dl); var seen = {}; (FILES.files || []).forEach(function (f) { var i = f.p.lastIndexOf("/"); if (i > 0) seen[f.p.slice(0, i)] = 1; });
      Object.keys(seen).sort().slice(0, 100).forEach(function (k) { var o = P.el("option"); o.value = k; dl.appendChild(o); });
    }
  }
  ["a-kind", "a-quality", "a-vformat", "a-aformat"].forEach(function (id) { $(id).addEventListener("input", function () { $("a-kind").dataset.touched = "1"; }); });
  $("a-folder-name").addEventListener("input", function () { if (P.S) fillAdd(P.S.status || {}); });
  $("a-go").onclick = function () {
    var urls = $("a-urls").value.split(/\r?\n/).map(function (s) { return s.trim(); }).filter(Boolean);
    if (!urls.length) { P.showErr("Paste at least one link."); return; }
    if (urls.length > 20) { P.showErr("Up to 20 links at a time."); return; }
    var bad = urls.filter(function (u) { return !/^https?:\/\/[A-Za-z0-9]\S*$/.test(u) || u.length > 1000; });
    if (bad.length) { P.showErr("Not a web link: " + bad[0].slice(0, 80)); return; }
    var pl = document.querySelector('input[name="a-pl"]:checked').value;
    act("dladd", { urls: urls.join("\n"), kind: $("a-kind").value, quality: $("a-quality").value, vformat: $("a-vformat").value, aformat: $("a-aformat").value,
      folder: $("a-folder-name").value.trim(), playlist: pl, limit: $("a-limit").value || 50 }).then(function () { $("a-urls").value = ""; });
  };

  // ------------------------------------------------------------ Library
  function loadFiles() { if (P.role !== "admin") return; P.api("action=files").then(function (f) { FILES = f; if (P.S && P.tab === "library") renderLibrary(P.S.status || {}); if (P.S && P.tab === "add") fillAdd(P.S.status || {}); }).catch(function () {}); }
  function renderLibrary(st) {
    var a = A(st), lib = a.library || {}, t = $("l-tiles"), d = A(st).defaults || {};
    $("l-path").textContent = (a.folder || {}).path || ""; folderBox($("l-folder"), st);
    P.clear(t); P.tile(t, (lib.count || 0).toLocaleString(), "files"); P.tile(t, P.bytes(lib.bytes || 0), "in the folder");
    P.tile(t, lib.disk_free != null ? P.bytes(lib.disk_free) : "–", "free on the volume"); if (lib.incomplete) P.tile(t, P.bytes(lib.incomplete), "unfinished downloads");
    if (FILES && (FILES.at || 0) < (lib.at || 0)) loadFiles();
    var tb = $("l-files"), q = $("l-q").value.trim().toLowerCase(), files = ((FILES || {}).files || []).filter(function (f) { return !q || f.p.toLowerCase().indexOf(q) >= 0; });
    if (changed(tb, (FILES ? FILES.at : 0) + "|" + q + P.role)) {
      P.clear(tb); if (!FILES) empty(tb, "Reading the folder…", 4); else if (!files.length) empty(tb, q ? "No file matches." : "The download folder is empty.", 4);
      files.slice(0, 500).forEach(function (f) {
        var c = P.el("input"); c.type = "checkbox"; c.value = f.p; c.className = "l-pick"; c.onchange = libButtons;
        var name = P.el("div"), i = f.p.lastIndexOf("/"); name.appendChild(P.el("div", i >= 0 ? f.p.slice(i + 1) : f.p, "dl-title")); if (i > 0) name.appendChild(P.el("div", f.p.slice(0, i), "dl-sub"));
        P.row(tb, [P.cell(c, "chk"), name, P.cell(P.bytes(f.s), "n"), P.cell(P.when(f.t), "nw")]);
      });
      $("l-all").checked = false;
      $("l-more").hidden = !(FILES && FILES.count > 500); $("l-more").textContent = FILES && FILES.count > 500 ? "The newest 500 of " + FILES.count.toLocaleString() + " files are shown; File Station has the rest." : "";
    }
    if (!$("l-clean-on").dataset.touched) { $("l-clean-on").checked = (d.clean_days || 0) > 0; if (d.clean_days) $("l-clean-days").value = d.clean_days; }
    libButtons();
  }
  function picked() { return Array.prototype.slice.call(document.querySelectorAll(".l-pick:checked")).map(function (c) { return c.value; }); }
  function libButtons() { $("l-del").disabled = !admin() || !picked().length; $("l-del").textContent = picked().length ? "Delete " + picked().length + " selected" : "Delete selected"; }
  $("l-all").onchange = function () { document.querySelectorAll(".l-pick").forEach(function (c) { c.checked = $("l-all").checked; }); libButtons(); };
  $("l-q").addEventListener("input", function () { if (P.S) renderLibrary(P.S.status || {}); });
  $("l-del").onclick = function () {
    var p = picked(); if (!p.length) return; if (p.length > 100) { P.showErr("Up to 100 files at a time."); return; }
    var body = p.join("\n"); if (body.length > 2800) { P.showErr("That's too many long names at once — pick fewer files."); return; }
    act("libdelete", { paths: body }, "Delete " + (p.length === 1 ? p[0] : p.length + " files") + " from the download folder?\n\nThey're gone for good — DSM's recycle bin doesn't catch them.").then(function () { setTimeout(loadFiles, 4000); });
  };
  ["l-clean-on", "l-clean-days"].forEach(function (id) { $(id).addEventListener("input", function () { $("l-clean-on").dataset.touched = "1"; }); });
  $("l-clean-save").onclick = function () {
    var on = $("l-clean-on").checked, n = parseInt($("l-clean-days").value, 10);
    if (on && !(n >= 1 && n <= 3650)) { P.showErr("Days from 1 to 3650."); return; }
    act("libclean", { days: on ? n : 0 }, on ? "From now on, files downloaded more than " + n + " days ago are deleted once a day — starting now. Go ahead?" : null).then(function () { $("l-clean-on").dataset.touched = ""; setTimeout(loadFiles, 4000); });
  };

  // ------------------------------------------------------------ Defaults
  (function () { var box = $("f-langs"); LANGS.forEach(function (l) { var lab = P.el("label"), c = P.el("input"); c.type = "checkbox"; c.value = l[0]; c.className = "f-lang"; lab.appendChild(c); lab.appendChild(document.createTextNode(" " + l[1])); box.appendChild(lab); }); })();
  var FORM = ["f-kind", "f-quality", "f-vformat", "f-aformat", "f-sub-auto", "f-thumb", "f-meta", "f-lan", "f-max"];
  function radio(name, v) { var r = document.querySelector('input[name="' + name + '"][value="' + v + '"]'); if (r) r.checked = true; }
  function radioVal(name) { var r = document.querySelector('input[name="' + name + '"]:checked'); return r ? r.value : ""; }
  function renderDefaults(st) {
    var a = A(st), d = a.defaults || {}, f = a.folder || {};
    if (!$("f-kind").dataset.touched && d.kind) {
      $("f-kind").value = d.kind; $("f-quality").value = d.quality; $("f-vformat").value = d.vformat; $("f-aformat").value = d.aformat;
      radio("f-tpl", d.tpl); radio("f-sub", d.sub_mode); document.querySelectorAll(".f-lang").forEach(function (c) { c.checked = (d.sub_langs || []).indexOf(c.value) >= 0; });
      $("f-sub-auto").checked = !!d.sub_auto; $("f-thumb").checked = !!d.thumb; $("f-meta").checked = !!d.meta; $("f-lan").checked = !!d.lan; $("f-max").value = String(d.max_dl || 3);
    }
    if (!$("f-dir").dataset.touched) $("f-dir").value = f.path || "";
    var fs = $("f-folder-state"); P.clear(fs);
    if (f.state === "ok") { var p = P.el("p"); p.appendChild(P.chip("MeTube can save here", "ok")); fs.appendChild(p); } else folderBox(fs, st);
    if (!$("n-done").dataset.touched) { $("n-done").checked = !!d.notify_done; $("n-failed").checked = !!d.notify_fail; }
  }
  FORM.forEach(function (id) { $(id).addEventListener("input", function () { $("f-kind").dataset.touched = "1"; }); });
  document.querySelectorAll('input[name="f-tpl"], input[name="f-sub"]').forEach(function (r) { r.addEventListener("input", function () { $("f-kind").dataset.touched = "1"; }); });
  $("f-langs").addEventListener("input", function () { $("f-kind").dataset.touched = "1"; });
  $("f-dir").addEventListener("input", function () { $("f-dir").dataset.touched = "1"; });
  ["n-done", "n-failed"].forEach(function (id) { $(id).addEventListener("input", function () { $("n-done").dataset.touched = "1"; }); });
  $("f-save").onclick = function () {
    var langs = Array.prototype.slice.call(document.querySelectorAll(".f-lang:checked")).map(function (c) { return c.value; });
    if (!langs.length) langs = ["en"]; if (langs.length > 5) { P.showErr("Up to five subtitle languages."); return; }
    act("defaults", { kind: $("f-kind").value, quality: $("f-quality").value, vformat: $("f-vformat").value, aformat: $("f-aformat").value, tpl: radioVal("f-tpl") || "title",
      sub_mode: radioVal("f-sub") || "off", sub_langs: langs.join("+"), sub_auto: $("f-sub-auto").checked ? 1 : 0, thumb: $("f-thumb").checked ? 1 : 0, meta: $("f-meta").checked ? 1 : 0,
      lan: $("f-lan").checked ? 1 : 0, max_dl: $("f-max").value }).then(function () { $("f-kind").dataset.touched = ""; $("a-kind").dataset.touched = ""; });
  };
  $("f-dir-save").onclick = function () {
    var v = $("f-dir").value.trim().replace(/\/+$/, "");
    if (!/^\/volume(USB)?[0-9]+(-[0-9]+)?\/[^\/@#][^\/]*(\/[^\/]+)*$/.test(v)) { P.showErr("A folder inside a shared folder, like /volume1/Downloads/MeTube."); return; }
    act("dlfolder", { dir: v }, "Save downloads to " + v + " from now on? MeTube restarts for a few seconds; files already downloaded stay where they are.").then(function () { $("f-dir").dataset.touched = ""; FILES = null; setTimeout(loadFiles, 6000); });
  };
  $("n-save").onclick = function () { act("notifyset", { done: $("n-done").checked ? 1 : 0, failed: $("n-failed").checked ? 1 : 0 }).then(function () { $("n-done").dataset.touched = ""; }); };

  // ------------------------------------------------------------ Share to MeTube
  function renderShare(st) {
    var a = A(st), d = a.defaults || {}, base = (a.url || "").replace(/\/$/, "");
    if (!changed($("s-url"), base + (a.qr || "").length + JSON.stringify(d))) return;
    $("s-qr").src = a.qr ? "data:image/png;base64," + a.qr : ""; $("s-url").textContent = base + "/";
    $("s-qr2").src = a.qr_share ? "data:image/png;base64," + a.qr_share : ""; $("s-url2").textContent = a.share_url || "";
    var code = "javascript:(function(){window.open('" + base + "/dsm-share.html?url='+encodeURIComponent(location.href),'_blank');})();";
    $("s-bm").href = code; $("s-bm").onclick = function (e) { e.preventDefault(); P.showErr("Drag it to the bookmarks bar rather than clicking it here."); };
    $("s-bm-code").textContent = code;
    $("s-ios-url").textContent = base + "/add"; $("s-ios-host").textContent = base.replace(/^https?:\/\//, "");
    var fields = d.kind === "audio" ? ["url = Shortcut Input", "download_type = audio", "format = " + (d.aformat || "mp3"), "quality = best"] : ["url = Shortcut Input", "download_type = video", "format = " + (d.vformat || "mp4"), "quality = " + (d.quality || "best")];
    $("s-ios-fields").textContent = fields.join(", ");
  }
  $("s-bm-copy").onclick = function () { P.copy($("s-bm-code").textContent, $("s-bm-copy"), $("s-bm-code")); };

  // ------------------------------------------------------------ yt-dlp
  function age(v) { var m = /^(\d{4})\.(\d{2})\.(\d{2})/.exec(v || ""); if (!m) return null; return Math.max(0, Math.floor((Date.now() - new Date(+m[1], +m[2] - 1, +m[3]).getTime()) / 86400000)); }
  function renderYtdlp(st) {
    var a = A(st), iu = st.image_update || {}, yv = a.ytdlp_version || "?", ag = age(yv), t = $("y-tiles"), w = $("y-warn");
    P.clear(t); P.tile(t, yv, "yt-dlp in MeTube"); P.tile(t, ag == null ? "–" : ag === 0 ? "today" : ag + (ag === 1 ? " day" : " days"), "since that yt-dlp came out");
    P.tile(t, a.metube_version || st.version || "?", "MeTube"); P.tile(t, iu.ytdlp_latest || "–", "newest yt-dlp");
    P.clear(w);
    var old = ag != null && ag > 45 && iu.ytdlp_latest && iu.ytdlp_latest !== yv, stale = (a.stale_failures || 0) >= 2;
    if (stale || old) { var d = P.el("div", null, "fix" + (stale ? "" : " warn")); d.appendChild(P.el("b", stale ? a.stale_failures + " downloads failed today in a way that usually means yt-dlp is out of date." : "This yt-dlp is " + ag + " days old, and yt-dlp " + iu.ytdlp_latest + " is out.")); d.appendChild(P.el("br"));
      d.appendChild(document.createTextNode(iu.available ? "MeTube " + iu.latest + " is out — Update below brings a current yt-dlp." : "No newer MeTube release is out yet; new ones usually follow yt-dlp within days. The package looks twice a day.")); w.appendChild(d); }
    var u = $("y-upd"); P.clear(u);
    u.appendChild(P.el("p", "Installed: MeTube " + (a.metube_version || st.version || "?") + " with yt-dlp " + yv + "."));
    if (iu.available) { u.appendChild(P.el("p", "MeTube " + iu.latest + " is out" + (iu.ytdlp_latest ? " (the newest yt-dlp is " + iu.ytdlp_latest + ")" : "") + ". Updating backs up MeTube's state first and takes a minute or two.", "muted small"));
      u.appendChild(P.btn("Update to MeTube " + iu.latest, "primary", function () { P.act("updateapp", null, "Update MeTube to " + iu.latest + " now? Its state is backed up first; downloads under way start again where they were."); })); }
    else u.appendChild(P.el("p", iu.error ? "Couldn't check: " + iu.error + "." : "MeTube is the newest release" + (iu.checked ? " (checked " + P.ago(iu.checked) + ")" : "") + ".", "muted small"));
    u.appendChild(P.el("span", " ")); u.appendChild(P.btn("Look for updates now", "", function () { P.act("check"); }));
  }

  // ------------------------------------------------------------ badges, overview, registration
  function badges(st) {
    var c = counts(data(st)), b = $("badge-downloads"); b.hidden = !c.failed; b.textContent = String(c.failed);
    var a = A(st), iu = st.image_update || {}, y = $("badge-ytdlp"); y.hidden = !(iu.available || (a.stale_failures || 0) >= 2); y.textContent = "!";
    var f = $("badge-defaults"), fs = (a.folder || {}).state; f.hidden = !fs || fs === "ok" || fs === "unknown"; f.textContent = "!";
  }
  P.register("overview", { tiles: function (t, st) {
    var a = A(st), c = counts(data(st)), lib = a.library || {};
    P.tile(t, String(c.queued), "in the queue"); P.tile(t, String(c.downloading), "downloading"); P.tile(t, String(c.today), "finished today"); P.tile(t, lib.bytes != null ? P.bytes(lib.bytes) : "–", "download folder");
  } });
  P.register("downloads", { render: function (st) { renderDownloads(st); }, show: startLive, badge: function (st) { badges(st); if (P.tab !== "downloads" && P.tab !== "overview") stopLive(); } });
  P.register("add", { render: fillAdd, show: function () { if (!FILES) loadFiles(); } });
  P.register("library", { render: renderLibrary, show: loadFiles });
  P.register("defaults", { render: renderDefaults });
  P.register("share", { render: renderShare });
  P.register("ytdlp", { render: renderYtdlp });
  P.register("storage", { render: function (app, st, box) {
    P.clear(box); var lib = A(st).library || {}, tb = P.el("tbody"), tab = P.el("table"); tab.appendChild(tb);
    P.kv(tb, "Download folder", (A(st).folder || {}).path || "–"); P.kv(tb, "Files there", (lib.count || 0).toLocaleString(), true); P.kv(tb, "Their size", P.bytes(lib.bytes || 0), true);
    P.kv(tb, "Free on its volume", lib.disk_free != null ? P.bytes(lib.disk_free) : "–", true); box.appendChild(tab);
  } });
})(window.Panel);
