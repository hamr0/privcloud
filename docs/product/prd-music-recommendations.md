# PRD: Music recommendations & auto playlists (Navidrome)

Status: **Tier 1 shipped** · Tiers 2–3 are future features.

## Goal

Give the music library a "Spotify-like" feel — playlists that refresh on their own based on
what's in the library and what's been played — while staying self-hosted and open-source.

## Background

- **Navidrome** already tracks play counts, last-played dates, ratings, and loved flags.
- **MusicBrainz** = metadata source. Tagging files (via Picard) with MusicBrainz IDs (MBIDs)
  makes scrobble matching and recommendations far more reliable. Plumbing, not a feature.
- **ListenBrainz** = open-source recommendation engine. You feed it your listen history
  (scrobbles); its algorithms (collaborative filtering + content similarity, via the "Troi"
  playlist tool) hand back generated playlists like *Daily Jams* and *Weekly Exploration* —
  including music you don't own. This is the part you outsource rather than build.

## Tier 1 — Smart playlists (`.nsp`) — ✅ DONE

Native Navidrome feature. JSON rule files dropped in the music folder, re-evaluated each scan.
Covers "random/curated playlists from my own library + play history" with zero code.

- Deliverable: `tools/navidrome/playlists/*.nsp` + `tools/navidrome/README.md`, auto-installed by
  `setup.sh` (`_install_smart_playlists`) into `$MUSIC_LOCATION/Playlists/` on Deploy and after a
  music-location change, so the files always follow the active music folder.
- Known limit: `random` sort reshuffles per load (not a fixed daily set) → motivates Tier 3.

## Tier 2 — ListenBrainz integration (future)

Get real recommendations from listening history.

- **Scrobbling:** Navidrome has native ListenBrainz support — add a user token in settings so
  plays are sent to ListenBrainz. Low effort; do this first regardless, it banks history.
- **Pull recommendations back in:** ListenBrainz generates *Daily Jams* etc. server-side. A
  sync step is needed to recreate those as Navidrome playlists, matching recommended tracks
  to owned files (by MBID, falling back to artist+title).
- **Open questions / risks:**
  - Matching quality depends on good tags → leans on MusicBrainz/Picard tagging first.
  - Recommendations of music *not* owned are useless on a self-hosted server unless acquired.
  - Pick: existing community sync script vs. our own small script. Evaluate before committing.
- **Effort:** scrobble setup ~15 min; reliable sync of playlists is the fiddly part.

## Tier 3 — Custom daily playlist script (future)

A cron job that builds and overwrites one playlist per day → stable during the day,
rotates at midnight (the thing `.nsp` random can't do).

- **Approach:** small script (Python/bash) that reads play data — either via the Subsonic API
  Navidrome exposes (`getRandomSongs`, `getStarred`, `getAlbumList?type=frequent/recent`) or by
  querying Navidrome's SQLite directly — then writes via `createPlaylist`/`updatePlaylist`.
- **Logic:** weighted mix, e.g. 40% recently played, 30% loved, 30% deep cuts not played in 6mo.
- **Integration:** fits the existing script/cron patterns in this repo; one playlist updated daily.
- **Effort:** ~1 evening. Only mild gotcha is Subsonic auth (token + salt + MD5).
- **Build only if** the Tier 1 reshuffle behavior proves annoying in daily use.

## Recommendation / sequencing

1. Tier 1 now (done).
2. Turn on ListenBrainz scrobbling early — free, and it accumulates the history Tiers 2/3 want.
3. Tag the library with Picard/MBIDs before investing in Tier 2 matching.
4. Tier 3 if/when "stable daily, rotates nightly, weighted my way" matters.
5. Don't build recommendation algorithms from scratch — that's ListenBrainz's job.
