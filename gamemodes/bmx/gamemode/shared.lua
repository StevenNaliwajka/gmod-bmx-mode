--[[--------------------------------------------------------------------------
    gamemodes/bmx/gamemode/shared.lua

    BMX (Mode): the gamemode for the BMX vehicle addon. Sandbox underneath (the
    spawn menu, the physgun, the park-piece tool all still work), plus what a
    BMX server plays: the games (SKATE, Trick Attack, Combo Mambo), personal
    bests and the leaderboard, and the trick bot.

    THE THREE PIECES, and which owns what:

        BMX              the vehicle addon (lua/autorun/bmx_init.lua, Workshop
                         3814420080): bikes, physics, tricks, combos and their
                         scoring, park pieces, cameras, replays. Rides on ANY
                         gamemode.
        BMX (Mode)       this gamemode: everything that only makes sense on a
                         BMX server. Built ONLY on the addon's public API --
                         BMX_* hooks (docs/MODDING.md in the addon), BMX.Settings,
                         BMX.AddPrivilege, BMX.Launch, BMX.Test.
        petopia_bmx_fall the map, with its city (its own addon).

    The addon's autorun has already run when this file loads (lua/autorun comes
    before the gamemode), so BMX is here -- unless the addon is not installed,
    which is the one thing this gamemode cannot work around.
----------------------------------------------------------------------------]]

DeriveGamemode("sandbox")

GM.Name    = "BMX (Mode)"
GM.Author  = "naliwajka"
GM.Website = "https://www.naliwajka.com/"

BMXMode = BMXMode or {}
BMXMode.Version = "1.0.0"

-- The addon's version this gamemode was written against: the games listen to
-- BMX_TrickLanded / BMX_ComboEnded / BMX_Crash, the bot drives BMX.Launch.
BMXMode.NeedsAddon = "1.1.0"

function BMXMode.AddonReady()
    return istable(BMX) and isstring(BMX.Version) and istable(BMX.Settings)
        and isfunction(BMX.AddPrivilege)
end

local SHARED = {
    "sh_settings.lua",   -- the mode's settings rows and its privilege, in the addon's menu
}

local SERVER_FILES = {
    "sv_scores.lua",     -- personal bests + leaderboard; listens to the addon's public hooks
    "sv_bot.lua",        -- a bot rider that does tricks (bmx_bot_spawn)
    "sv_board_bot.lua",  -- ...and its skateboard tricks (needs the addon's G23 skateboard; inert without it)
    "sv_botnav.lua",     -- the bot routed on the addon's navmesh (BMX.Nav): paths, ramps, runways
    "sv_botavatar.lua",  -- the bot's picture (bmx_bot_avatar) and the join card
    "sv_games.lua",      -- SKATE, Trick Attack, Combo Mambo (loads games/*)
    "sv_tidy.lua",       -- anything spawned and left untouched for bmx_idle_cleanup seconds is removed
    "sv_test_cases.lua", -- the bot's cases for the addon's headless suite (bmx_test bot_*)
}

local CLIENT_FILES = {
    "cl_scores.lua",     -- after the addon's cl_hud: it borrows that file's fonts
    "cl_games.lua",
    "cl_botavatar.lua",  -- the bot's picture on every scoreboard, and the join card
}

BMXMode.Files = { shared = SHARED, server = SERVER_FILES, client = CLIENT_FILES }

function BMXMode.Load()
    if not BMXMode.AddonReady() then
        ErrorNoHalt("[BMX (Mode)] the BMX vehicle addon is not installed (or is older than "
            .. BMXMode.NeedsAddon .. "): the games, scores and bot are off. "
            .. "Subscribe to Workshop item 3814420080.\n")
        return false
    end
    if SERVER then
        for _, f in ipairs(SHARED) do AddCSLuaFile(f) end
        for _, f in ipairs(CLIENT_FILES) do AddCSLuaFile(f) end
    end
    for _, f in ipairs(SHARED) do include(f) end
    if SERVER then
        for _, f in ipairs(SERVER_FILES) do include(f) end
    else
        for _, f in ipairs(CLIENT_FILES) do include(f) end
    end
    MsgN("[BMX (Mode)] ", BMXMode.Version, " loaded (", SERVER and "server" or "client",
        ") on BMX ", BMX.Version)
    return true
end
