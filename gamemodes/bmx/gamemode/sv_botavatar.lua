--[[--------------------------------------------------------------------------
    gamemodes/bmx/gamemode/sv_botavatar.lua

    The bot rider's picture. A bot has no Steam account, so the scoreboard
    shows it the grey "?" avatar. With a picture set, every client draws that
    instead (cl_botavatar.lua), and a card pops up as the bot joins.

        bmx_bot_avatar ""   a PNG/JPG URL (https://...) or a material path
                            the server sends ("materials/..."); empty = none

    Like bmx_bot_model, THE PICTURE IS NOT IN THIS ADDON: the server owner
    points the convar at one they host.
----------------------------------------------------------------------------]]

BMX = BMX or {}
local Bot = BMX.Bot
if not Bot then return end

local cvAvatar = CreateConVar("bmx_bot_avatar", "", bit.bor(FCVAR_ARCHIVE, FCVAR_REPLICATED),
    "BMX: picture for bot riders on the scoreboard and the join card: an https URL to a PNG/JPG, or a material path. Empty = none.")

-- Clients read it as a networked global.
local function publish() if SetGlobalString then SetGlobalString("BMXBotAvatar", cvAvatar:GetString()) end end
cvars.AddChangeCallback("bmx_bot_avatar", publish, "BMX.BotAvatar")
publish()
hook.Add("InitPostEntity", "BMX.BotAvatar", publish)

util.AddNetworkString("bmx_bot_joined")

-- Say a bot joined, once it exists on the clients (it is created this tick).
function Bot.Announce(ply)
    if not IsValid(ply) then return end
    if ply.SetNWBool then ply:SetNWBool("BMXBot", true) end
    timer.Simple(1, function()
        if not IsValid(ply) then return end
        net.Start("bmx_bot_joined")
        net.WriteEntity(ply)
        net.WriteString(ply:Nick())
        net.Broadcast()
    end)
end

Bot.origSpawn = Bot.origSpawn or Bot.Spawn
function Bot.Spawn(...)
    local b, why = Bot.origSpawn(...)
    if b and IsValid(b.ply) then Bot.Announce(b.ply) end
    return b, why
end
