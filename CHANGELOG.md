# Changelog

## 1.0.0 — 2026-10-19

- MeTube 2026.10.19 (from ghcr.io, pinned) in Container Manager, running as
  the package's own user, so downloads belong to it.
- The install wizard suggests a free port and the download folder: a folder
  in a shared folder (`/volume1/Downloads/MeTube` when there's a `Downloads`
  share). The package makes that folder when it may write in the shared
  folder, never the shared folder itself, and shows DSM's permission steps
  when it can't write there.
- **Downloads:** the queue live, with progress, speed and time left; finished
  downloads with size, folder and date; failed ones with the reason and
  Retry; stop, remove, delete the file too, clear finished or failed.
- **Add:** up to 20 links at once, video (quality, MP4 or best available) or
  audio only (MP3, M4A, Opus), a subfolder, just the video or the whole
  playlist up to a limit — checked in the CGI and again in the setup
  container.
- **Library:** the download folder's files with size and date, total size,
  free space, delete selected; an optional daily "keep only the last N days"
  clean-up.
- **Defaults:** what to download, safe file name presets, subtitles (files or
  inside the video, up to five languages), cover art and metadata, downloads
  at once, links on the own network, the download folder, DSM notifications.
- **Share to MeTube:** QR codes, a share page MeTube serves, a bookmarklet,
  an iPhone Shortcut and Android steps with this NAS's address.
- **yt-dlp:** its version and age, the newest releases, and an update to the
  newest MeTube release (a backup first, only the old image removed); a DSM
  notification when downloads fail the way an outdated yt-dlp makes them.
- DSM notifications for failed downloads and, if you like, finished ones.
- Backups of MeTube's state (queue, history, subscriptions, cookies) with
  restore; the downloaded media stays in your shared folder.
