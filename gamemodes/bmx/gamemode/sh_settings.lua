--[[--------------------------------------------------------------------------
    gamemodes/bmx/gamemode/sh_settings.lua

    The mode's own settings and privilege, added to the addon's single list
    (BMX.Settings, the addon's sh_settings.lua) so they appear in the same
    Options > BMX menu, reset with bmx_reset_server and save in server.json.
    The convars themselves are created where they always were (sv_bot.lua,
    sv_games.lua), under the same names.
----------------------------------------------------------------------------]]

local S = BMX.Settings

S.AddCategory("server", "bots", "Bot riders")

S.Add{ scope = "server", name = "bmx_bot_name", kind = "string", default = "Peter Griffin", maxLen = 32,
    category = "bots", label = "Bot name",
    help = "What a bot rider spawned with bmx_bot_spawn is called." }
S.Add{ scope = "server", name = "bmx_bot_model", kind = "string", default = "", maxLen = 128,
    category = "bots", label = "Bot player model",
    help = "The player model bot riders wear. Empty uses the default. The server must have the model installed." }
S.Add{ scope = "server", name = "bmx_bot_avatar", kind = "string", default = "", maxLen = 256,
    category = "bots", label = "Bot picture",
    help = "A picture for bot riders on the scoreboard and on the card shown as one joins: an https link to a PNG or JPG, or a material path. Empty shows none." }
S.Add{ scope = "server", name = "bmx_bot_nav", kind = "bool", default = true,
    category = "bots", label = "Bots use the navmesh",
    help = "Bot riders route round the park on the map's navmesh (bmx_nav_build makes one) and pick their ramps and runways from it. Off, they ride in straight lines." }
S.Add{ scope = "server", name = "bmx_games_admin_only", kind = "bool", default = false,
    category = "rules", label = "Only admins start games",
    help = "Only admins may start a game of SKATE or another BMX game. Off lets any player start one." }
S.Add{ scope = "server", name = "bmx_idle_cleanup", kind = "int", default = 120, min = 0, max = 3600,
    category = "rules", label = "Clear untouched spawns after (s)",
    help = "Anything a player spawned (props, park pieces, bikes, rentals) is removed once nobody has ridden, held, used, moved or stood on it for this many seconds. 0 never clears." }

BMX.AddPrivilege{ name = "BMX - Bot", min = "admin",
    desc = "Spawn and command bot riders (bmx_bot_*)." }
