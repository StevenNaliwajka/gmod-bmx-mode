# BMX (Mode): hooks and commands

The gamemode's own public hooks, and its commands. Everything here is built on
the BMX vehicle addon's hooks (`BMX_TrickLanded`, `BMX_ComboBanked`,
`BMX_Crash`, ...), documented in the addon's `docs/MODDING.md`.

## Hooks: scores and games

### `BMX_NewBest` (ply, stat, value, bikeId)

*Server.* A player beat their own best. `stat` is `combo`, `trick`, `grind`,
`manual` or `air`; `value` is points or seconds. Bots, noclip and
physgun-carried bikes never fire it (`BMX.Scores.Counts`).

### `BMX_GameStarted` (game)

*Server.* A SKATE / Trick Attack / Combo Mambo lobby began. `game.id`,
`game.players`.

### `BMX_GameEnded` (game, result)

*Server.* A game finished. `result.winner` is the winning player (nil for a
draw) and `result.ranking` the standings. Pay out here.

### `BMX_GameLetter` (game, ply, word, out)

*Server.* A SKATE player got a letter. `word` is what they have spelled so far;
`out` is true when it completes the word.


### Client

### `BMX_ScoresUpdated` (cache)

*Client.* The server answered a `bmx_scores` request.


## Commands

| Command | |
|---|---|
| `bmx_scores` (client) | The panel: top ten of each stat for this map. |
| `bmx_scores_reset` (superadmin) | Wipe this map's scores. |
| `bmx_game_start skate\|attack\|mambo [bot]` | Open a lobby; the host runs it again to begin. |
| `bmx_game_join`, `bmx_game_leave`, `bmx_game_status` | |
| `bmx_games_admin_only 1` | Only admins may start a game. |
| `bmx_leaderboard_set <stat\|all> [bike]` | Admin: on the leaderboard sign you are looking at. |

Scores are saved to `data/bmx/scores/<map>.json`: the top ten of each stat, per
bike, written at most every 30 seconds and on shutdown.
