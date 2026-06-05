# Navidrome smart playlists (`.nsp`)

Auto-updating playlists that Navidrome builds from your own library + play history.
No code, no API — just JSON files Navidrome reads during its hourly scan.

## How they work

- One `.nsp` file = one playlist. The `name` field is what shows in the app.
- Navidrome re-evaluates the rules every scan (`ND_SCANSCHEDULE: 1h` in `docker-compose.yml`),
  so they stay current as your play counts and "loved" flags change.
- They read data Navidrome already tracks: `playCount`, `lastPlayed`, `loved`, `rating`,
  `dateAdded`, `genre`, `year`, `artist`, etc.

## Where to put them

Anywhere inside your music library — the folder mounted as `/music`
(`MUSIC_LOCATION`, default `/mnt/data/media/My Music`). A `Playlists/` subfolder is tidy.

Two ways to deploy the files in `playlists/`:

1. **FileBrowser (easiest):** open FileBrowser → `media/My Music/` → upload the `.nsp` files.
2. **SSH/scp:** copy them into `$MUSIC_LOCATION/` on the server.

Then either wait up to an hour, or trigger a scan now from the Navidrome web UI
(top-right menu → **Rescan**). The playlists appear under **Playlists**.

## The files here

| File | What it gives you |
|------|-------------------|
| `daily-mix.nsp` | Loved or already-played tracks not heard in the last 7 days, shuffled |
| `rediscover.nsp` | Played at least once but not in the last month |
| `on-repeat.nsp` | Your most-played tracks of the last month |
| `decade-90s.nsp` | Everything tagged 1990–1999, shuffled *(needs `year` tags)* |
| `decade-2000s.nsp` | Everything tagged 2000–2009, shuffled *(needs `year` tags)* |
| `throwback.nsp` | Everything tagged before 2010, shuffled *(needs `year` tags)* |
| `surprise-me.nsp` | Pure shuffle of the whole library (no tags or history needed) |

Tweak the numbers (day windows, play counts, year ranges, limits…) to taste.

**Note on the year playlists:** they read each file's `year` ID3 tag, not the
file date. If they come back empty, the files are missing year tags — tag the
library with [MusicBrainz Picard](https://picard.musicbrainz.org/) to fix it.

**Excluding a folder:** every list above excludes the `Holy Quraan` folder so
recitations never land in a music shuffle, via this line in each `all` block:

```json
{ "notContains": { "filepath": "Holy Quraan" } }
```

`filepath` matches the file's full path, so the folder name as a substring is
enough. Add the same line (with your own folder name) to any playlist to keep
that folder out of it.

## Honest caveats

- **"Random" reshuffles often, it's not a fixed daily set.** A `"sort": "random"` playlist
  gets a new order on (re)load, not "the same list all of Tuesday, new one Wednesday."
  If you want a stable-then-rotating daily playlist, that's Tier 3 in
  `docs/prd-music-recommendations.md` (a small cron script).
- **Field names can vary slightly by Navidrome version.** If a playlist shows up empty,
  check the Navidrome log for a parse error and confirm the field name against the docs:
  https://www.navidrome.org/docs/usage/smartplaylists/
- **Clients can play these but not create them.** `.nsp` is a server-side file feature.
  Arpeggi (and other Subsonic apps) will see and play the resulting playlist, but you
  can't author/edit the rules from the app — edit the files via FileBrowser or SSH.
