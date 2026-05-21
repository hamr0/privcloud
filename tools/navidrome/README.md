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
| `daily-mix.nsp` | Loved / well-played tracks not heard in the last 7 days, shuffled |
| `rediscover.nsp` | Stuff you used to play but haven't in 6 months |
| `on-repeat.nsp` | Your most-played tracks of the last month |
| `fresh-additions.nsp` | Anything added to the library in the last 30 days |
| `surprise-me.nsp` | Pure shuffle of the whole library |

Tweak the numbers (`7`, `180`, `2`, `50`…) to taste.

## Honest caveats

- **"Random" reshuffles often, it's not a fixed daily set.** A `"sort": "random"` playlist
  gets a new order on (re)load, not "the same list all of Tuesday, new one Wednesday."
  If you want a stable-then-rotating daily playlist, that's Tier 3 in
  `docs/prd-music-recommendations.md` (a small cron script).
- **Field names can vary slightly by Navidrome version.** If a playlist shows up empty,
  check the Navidrome log for a parse error and confirm the field name against the docs:
  https://www.navidrome.org/docs/usage/smartplaylists/
- **Clients can play these but not create them.** `.nsp` is a server-side file feature.
  Amperfy (and other Subsonic apps) will see and play the resulting playlist, but you
  can't author/edit the rules from the app — edit the files via FileBrowser or SSH.
