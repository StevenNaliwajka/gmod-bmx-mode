--[[--------------------------------------------------------------------------
    gamemodes/bmx/gamemode/sv_autoride.lua

    AUTO RIDE, driven by the trick bot. The addon has the button (O, the /bike
    window, bmx_autoride: its lua/bmx/sh_autoride.lua) and asks whoever
    drives through BMX_AutoRideStart. The driver is the bot's own brain,
    attached to the PLAYER'S bike with the player on it: the same routes on
    the navmesh (sv_botnav.lua), the same ramps, runways and rails off the map
    as it is (sv_botmap.lua), the same show of tricks, the same way out when
    it is stuck, and back on the bike after a fall. Exactly as Peter rides,
    because it is what Peter rides with.

    What differs from a bot is only what has to:

      quiet       no "[BMX] <name> landed a ..." to the server for every trick
      the bike    is the player's: never removed with the brain
      letting go  on BMX_AutoRideStop (a ride key, O, death, ...) the brain is
                  detached and the keys are the player's again; and a brain
                  that ends by itself (its bike gone, bmx_bot_remove) tells
                  the addon, so the HUD and the keys agree

    It only takes what the bot can ride: bikes with the bike's controls
    (BMX, road bike, fixie, city bike, the e-bikes) and the skateboard. Not
    during a game a player is in: a game counts a scripted rider for nothing,
    and their turns would go by.

    Nothing an auto ride lands is scored: the rider is scripted, and
    BMX.Scores.Counts says no to a scripted rider.
----------------------------------------------------------------------------]]

BMX = BMX or {}
local Bot = BMX.Bot
if not (Bot and Bot.Attach and Bot.Detach) then return end

local AutoRide = {}
Bot.AutoRide = AutoRide

-- The input maps (the addon's sh_vehicles.lua and friends) the bot's brain
-- knows how to drive.
AutoRide.Maps = { bike = true, road = true, bike_rearonly = true, ebike = true, board = true }

function AutoRide.CanRide(bike)
    local map = BMX.InputMapFor and BMX.InputMapFor(bike)
    return map ~= nil and AutoRide.Maps[map.id] == true
end

local function inGame(ply)
    local g = BMX.Games and BMX.Games.Active and BMX.Games.Active()
    if not g or g.state == "done" then return false end
    for _, p in ipairs(g.players or {}) do if p == ply then return true end end
    return false
end

hook.Add("BMX_AutoRideStart", "BMXMode.AutoRide", function(ply, bike)
    if Bot.brains[ply] then return false, "the bot is already riding for you" end
    if not AutoRide.CanRide(bike) then return false, "the auto rider cannot ride this one" end
    if inGame(ply) then return false, "not during a game" end
    local b = Bot.Attach(ply, bike, { quiet = true, home = bike:GetPos() })
    b.autoRide = true
    b.show = true
    b:say("auto ride: on, for " .. ply:Nick())
    return true
end)

hook.Add("BMX_AutoRideStop", "BMXMode.AutoRide", function(ply, bike, why)
    local b = Bot.brains[ply]
    if not (b and b.autoRide) then return end
    b:say("auto ride: off (" .. tostring(why) .. ")")
    b.autoRideStopping = true
    Bot.Detach(b)
end)

-- A brain let go of by anything else -- its bike removed (Bot.Think), every
-- bot removed (bmx_bot_remove) -- is an auto ride over. Wrapped once: a reload
-- of this file must not wrap the wrapper.
Bot.autoRideDetach = Bot.autoRideDetach or Bot.Detach
function Bot.Detach(b)
    Bot.autoRideDetach(b)
    if b and b.autoRide and not b.autoRideStopping and IsValid(b.ply) and BMX.AutoRide then
        BMX.AutoRide.Stop(b.ply, "the auto rider let go")
    end
end
