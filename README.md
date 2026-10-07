# BMX (Mode)

The gamemode for the **BMX** vehicle addon: `gamemodes/bmx`, shown in the
gamemode list as **BMX (Mode)**. It derives from sandbox, so the spawn menu,
the physgun and the BMX park-piece tool all still work, and adds what a BMX
server plays:

- **Games**: SKATE, Trick Attack and Combo Mambo (`bmx_game_start ...`).
- **Scores**: personal bests per player, per bike, per map, and a leaderboard
  sign (`bmx_scores`, `bmx_leaderboard_set`).
- **The trick bot**: `bmx_bot_spawn`, Peter Griffin by default.

## The three pieces

| Piece | Repository | What it is |
|---|---|---|
| **BMX** | root/gmod-bmx | The vehicle mod (Workshop 3814420080). Bikes, physics, tricks, combos, park pieces, cameras, replays. Works on any gamemode. |
| **BMX (Mode)** | root/gmod-bmx-mode (this) | The gamemode. |
| **petopia_bmx_fall** | root/petopia_bmx_fall | The map: an original BSP of the park, plus its city. |

This gamemode **needs the BMX addon** (1.1.0 or later) and uses only its
public API: the `BMX_*` hooks, `BMX.Settings`, `BMX.AddPrivilege`,
`BMX.Launch` and `BMX.Test`. Without the addon it loads and says so, and does
nothing else. It plays on any map; `bmx.txt` suggests it for
`petopia_bmx_fall` and `gm_skatepark`.

## Layout

```
gamemodes/bmx/bmx.txt                       the gamemode's manifest (base sandbox)
gamemodes/bmx/gamemode/shared.lua           GM table, DeriveGamemode, the file lists
gamemodes/bmx/gamemode/init.lua, cl_init.lua
gamemodes/bmx/gamemode/sh_settings.lua      its rows in the addon's Options > BMX, and "BMX - Bot"
gamemodes/bmx/gamemode/sv_games.lua         games/skate.lua, attack.lua, mambo.lua
gamemodes/bmx/gamemode/sv_scores.lua        personal bests, saved to data/bmx/scores/<map>.json
gamemodes/bmx/gamemode/sv_bot.lua           the trick bot
gamemodes/bmx/gamemode/sv_board_bot.lua     ...its skateboard tricks (when the addon has the skateboard)
gamemodes/bmx/gamemode/sv_test_cases.lua    the bot's cases in the addon's headless suite (bmx_test bot_*)
gamemodes/bmx/gamemode/cl_games.lua, cl_scores.lua
gamemodes/bmx/entities/entities/bmx_leaderboard/
```

## Running it

On a server with the BMX addon installed, put this repository's `gamemodes/bmx`
into `garrysmod/gamemodes/` (or the whole repository into `garrysmod/addons/`)
and start with `+gamemode bmx`. Clients get the Lua from the server; they need
the BMX addon from the Workshop.

## Tests

    lua5.1 tests/run.lua

runs this repository's tests on the BMX addon's offline harness: the addon's
GMod shim boots the real addon, then this gamemode on top. It finds the addon
at `$BMX_ADDON`, else `../gmod-bmx`, else `tests/.addon`. The bot's real-server
cases run with the addon's headless suite (`bmx_test bot_*`) on a server where
this gamemode is on.

## The trick bot

An admin (or the server console) can put a bot rider on a bike that rides
around and does tricks on its own:

```
bmx_bot_spawn [stock|cruiser|mini]   a bot on a bike where you are looking
bmx_bot_trick Backflip                every bot does that trick next
bmx_bot_status                        what each bot has tried and landed
bmx_bot_remove                        every bot rider gone, with its bikes and ramps
```

It works through Bunny Hop, Wheelie, Stoppie, Combo, Backflip, Frontflip,
Barrel Roll, 360, Crank Grind and Double Peg Grind (plus the style tricks in
the trick registry), announces each landing in chat, and gets back on after a
crash. It drives the bike exactly the way a player's keys do, and each trick
counts only if the addon's own scoring pays it. For air it looks for a ramp in
the map (any 12-40 degree slope that ends in a lip, with room before and
after); with none it puts its own kicker down and takes it away afterwards.
Every trick is a case in the headless suite (`bmx_test bot_*`), ridden on a
real server.

`bmx_bot_name` (default `Peter Griffin`) and `bmx_bot_model` name and dress
it. **The model is not part of this addon**, which ships no content that is
not its own: mount a player model on your server (from the Workshop, say) and
point `bmx_bot_model` at it. Players need it too, so add the Workshop item
with `resource.AddWorkshop`.


**On a navmesh** (the addon's `bmx_nav_build` makes one; a map can ship its
`maps/<map>.nav`), the bot routes round the park instead of riding straight
at things: an A* path with the corners taken slow, replanned once if it gets
stuck. It picks its ramps from every launch on the map, by height and angle,
by how far they are on the mesh, by how recently it used them, and by what
they have actually done for it -- a ramp it has missed off more often than it
has landed off is dropped, and then it puts a kicker down on the best long
runway the mesh knows instead. Flat tricks and rails get a catalogued runway
it can ride straight into, along the park's axes where it can.
`bmx_bot_nav 0` turns all of this off.

`bmx_bot_avatar` gives bot riders a picture: an https link to a PNG or JPG
(or a material path). Every scoreboard draws it over the bot's blank Steam
avatar, and a card with it pops up as the bot joins. Like the model, the
picture is not part of this gamemode: host one and point the setting at it.
