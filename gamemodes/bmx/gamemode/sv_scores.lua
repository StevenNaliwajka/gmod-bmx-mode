--[[--------------------------------------------------------------------------
    gamemodes/bmx/gamemode/sv_scores.lua

    PERSONAL BESTS AND THE LEADERBOARD. Scoring already existed (points, combos)
    and then threw every number away the moment the combo banked. This keeps the
    ones worth coming back for, per player, per map, per bike:

        combo    the biggest banked combo (points, bonus included)
        trick    the biggest single trick
        grind    the longest grind (seconds)
        manual   the longest wheelie or stoppie (seconds)
        air      the biggest air under a scored landing (seconds)

    WHERE IT HEARS ABOUT THEM. From the PUBLIC hooks (docs/MODDING.md), not from
    the bike's internals: BMX_TrickLanded and BMX_ComboBanked. That is on
    purpose. It makes this file the first customer of the modding API, so the
    day a hook's arguments change, this is what breaks first, in the offline
    suite, instead of a gamemode on somebody's server.

    WHAT IS KEPT: THE TOP TEN OF EACH STAT, and nothing else. A server with a
    few hundred regulars would otherwise write a few hundred records every time
    anyone landed anything. The price is stated plainly: a player who is not in
    the top ten of a stat has no saved best for it, only the best of this
    session, so a "NEW BEST" for them means "new best since you joined" until
    they make the table. Ten is the table the sign and the panel show, so
    nothing visible is lost.

    WHEN IT IS WRITTEN. Dirty flag, one write per 30 s at most, and once more on
    ShutDown. Never on the trick: a combo landing is the hottest moment on the
    server and file.Write is a disk write. A crash loses at most 30 s of bests.

    WHAT DOES NOT COUNT (S.Counts): a bot rider (bmx_bot_*, anything scripted),
    a noclipping rider, and a bike that is or was just in somebody's physgun. A
    leaderboard somebody can top by carrying a bike up a tower and dropping it
    is not a leaderboard. The trick bot is still welcome in a game (sv_games.lua
    asks for it explicitly); it just never lands in the table.
----------------------------------------------------------------------------]]

BMX = BMX or {}
BMX.Scores = BMX.Scores or {}
local S = BMX.Scores

util.AddNetworkString("bmx_newbest")
util.AddNetworkString("bmx_scores_req")
util.AddNetworkString("bmx_scores")

S.Stats  = { "combo", "trick", "grind", "manual", "air" }
S.Labels = { combo = "Best combo", trick = "Best trick", grind = "Longest grind",
             manual = "Longest manual", air = "Biggest air" }
-- Points, or seconds. The wire and the file keep the raw number; this is how
-- the HUD, the panel and the sign print it.
S.Units  = { combo = "pts", trick = "pts", grind = "s", manual = "s", air = "s" }
S.TopN      = 10
S.SaveEvery = 30           -- seconds between writes, at most
S.CarryGrace = 3           -- seconds a bike stays "carried" after the physgun lets go
S.Dir = "bmx/scores"

-- { bikes = { [bikeId] = { [stat] = { { sid=, name=, v= }, ... best first } } } }
S.data    = S.data or { bikes = {} }
S.session = S.session or {}    -- [sid][bikeId][stat] = best since this server started
S.dirty   = false

local isTime = { grind = true, manual = true, air = true }

local function round(stat, v)
    if isTime[stat] then return math.floor(v * 100 + 0.5) / 100 end
    return math.floor(v)
end

--------------------------------------------------------------------------
-- Persistence
--------------------------------------------------------------------------
function S.Path()
    -- A map name is a file name here, and a hostile or odd one must not be able
    -- to climb out of the folder.
    local map = tostring(game.GetMap() or "unknown"):gsub("[^%w_%-]", "_")
    return S.Dir .. "/" .. map .. ".json"
end

function S.Load()
    S.data = { bikes = {} }
    local raw = file.Read(S.Path(), "DATA")
    if not raw or raw == "" then return end
    local t = util.JSONToTable(raw)
    if type(t) ~= "table" or type(t.bikes) ~= "table" then
        ErrorNoHalt("[BMX] " .. S.Path() .. " is not a scores file; starting empty\n")
        return
    end
    S.data = t
end

function S.Save(force)
    if not force and not S.dirty then return false end
    file.CreateDir(S.Dir)
    file.Write(S.Path(), util.TableToJSON(S.data))
    S.dirty = false
    return true
end

--------------------------------------------------------------------------
-- What counts
--------------------------------------------------------------------------
-- `allowScripted`: a game that has invited a bot to play passes true for it.
function S.Counts(ply, bike, allowScripted)
    if not IsValid(ply) then return false, "no player" end
    if ply:IsBot() and not allowScripted then return false, "bot" end
    if ply.BMXScripted and not allowScripted then return false, "scripted" end
    if ply.GetMoveType and ply:GetMoveType() == MOVETYPE_NOCLIP then return false, "noclip" end
    if IsValid(bike) then
        if bike.BMXCarried then return false, "physgun" end
        if CurTime() < (bike.BMXCarriedUntil or 0) then return false, "physgun" end
    end
    return true
end

-- Held in a physgun, or dropped out of one a moment ago. Only an EMPTY bike
-- can be held (sv_seat.lua refuses a ridden one), so a pickup that this hook
-- sees on a ridden bike is one another hook already vetoed and is ignored.
hook.Add("PhysgunPickup", "BMX.Scores.Carry", function(ply, ent)
    if IsValid(ent) and ent.IsBMX and not IsValid(ent:GetDriver()) then
        ent.BMXCarried = true
    end
end)
hook.Add("PhysgunDrop", "BMX.Scores.Carry", function(ply, ent)
    if IsValid(ent) and ent.IsBMX then
        ent.BMXCarried = false
        ent.BMXCarriedUntil = CurTime() + S.CarryGrace
    end
end)

--------------------------------------------------------------------------
-- The tables
--------------------------------------------------------------------------
local function sidOf(ply)
    return ply:SteamID64() or ("bot:" .. ply:Nick())
end

local function list(bikeId, stat, create)
    local b = S.data.bikes[bikeId]
    if not b then
        if not create then return nil end
        b = {}
        S.data.bikes[bikeId] = b
    end
    local l = b[stat]
    if not l and create then l = {}; b[stat] = l end
    return l
end

local function sorted(l)
    table.sort(l, function(a, b)
        if a.v ~= b.v then return a.v > b.v end
        return tostring(a.sid) < tostring(b.sid)    -- a tie is stable, not a coin flip
    end)
end

-- A player's best for a stat on a bike: the saved one if they are in the
-- table, and the session's, whichever is better. nil if they have none.
function S.Personal(ply, stat, bikeId)
    local sid = sidOf(ply)
    local best = ((S.session[sid] or {})[bikeId] or {})[stat]
    local l = list(bikeId, stat)
    if l then
        for _, e in ipairs(l) do
            if e.sid == sid and (not best or e.v > best) then best = e.v end
        end
    end
    return best
end

-- Record a value. Returns true if it beat the player's own best (a "NEW BEST").
function S.Record(ply, bikeId, stat, v)
    if not IsValid(ply) or type(v) ~= "number" or v ~= v then return false end
    v = round(stat, v)
    if v <= 0 then return false end

    local before = S.Personal(ply, stat, bikeId)
    local isNew = before == nil or v > before
    if not isNew then return false end

    local sid = sidOf(ply)
    S.session[sid] = S.session[sid] or {}
    S.session[sid][bikeId] = S.session[sid][bikeId] or {}
    S.session[sid][bikeId][stat] = v

    local l = list(bikeId, stat, true)
    local mine
    for _, e in ipairs(l) do if e.sid == sid then mine = e break end end
    if mine then
        mine.v, mine.name = v, ply:Nick()
    else
        l[#l + 1] = { sid = sid, name = ply:Nick(), v = v }
    end
    sorted(l)
    while #l > S.TopN do table.remove(l) end
    S.dirty = true

    hook.Run("BMX_NewBest", ply, stat, v, bikeId)
    return true
end

-- The table for a stat. bikeId nil = every bike, each player once at their best.
function S.Top(stat, bikeId)
    if bikeId and bikeId ~= "" then
        local out = {}
        for i, e in ipairs(list(bikeId, stat) or {}) do out[i] = e end
        return out
    end
    local best = {}
    for _, perBike in pairs(S.data.bikes) do
        for _, e in ipairs(perBike[stat] or {}) do
            local cur = best[e.sid]
            if not cur or e.v > cur.v then best[e.sid] = e end
        end
    end
    local out = {}
    for _, e in pairs(best) do out[#out + 1] = e end
    sorted(out)
    while #out > S.TopN do table.remove(out) end
    return out
end

--------------------------------------------------------------------------
-- Listening: the public hooks, and nothing else
--------------------------------------------------------------------------
local function bikeIdOf(bike)
    return (IsValid(bike) and bike.BikeID) or "stock"
end

local function celebrate(ply, stat, v)
    local idx = 1
    for i, s in ipairs(S.Stats) do if s == stat then idx = i end end
    net.Start("bmx_newbest")
        net.WriteUInt(idx, 3)
        net.WriteFloat(v)
    net.Send(ply)
end

local function note(ply, bike, stat, v)
    if S.Record(ply, bikeIdOf(bike), stat, v) then
        celebrate(ply, stat, round(stat, v))
    end
end

-- Scoring off (bmx_scoring 0) never reaches here: the tricks do not fire.
hook.Add("BMX_TrickLanded", "BMX.Scores", function(ply, trick, points, bike)
    if not S.Counts(ply, bike) then return end
    note(ply, bike, "trick", points)
    -- The extra fields the scoring puts on a trick: how long it was held, how
    -- long it was on a rail, how long the bike was up. Absent = not that kind.
    if trick.held  then note(ply, bike, "manual", trick.held) end
    if trick.grind then note(ply, bike, "grind", trick.grind) end
    if trick.air and trick.air > 0 then note(ply, bike, "air", trick.air) end
end)

hook.Add("BMX_ComboBanked", "BMX.Scores", function(ply, chain, total)
    local bike = IsValid(ply) and ply.BMXBike or nil
    if not S.Counts(ply, bike) then return end
    note(ply, bike, "combo", total)
end)

--------------------------------------------------------------------------
-- Writing it down: batched, and once on the way out.
--------------------------------------------------------------------------
timer.Create("BMX.Scores.Save", S.SaveEvery, 0, function() S.Save() end)
hook.Add("ShutDown", "BMX.Scores.Save", function() S.Save() end)

--------------------------------------------------------------------------
-- The wire. A client asks (the panel, a leaderboard sign) and is answered with
-- the top ten of every stat plus its own bests. Rate-limited per player,
-- because a sign on every client asks, and a client can ask in a loop.
--------------------------------------------------------------------------
local function send(ply, bikeId)
    net.Start("bmx_scores")
        net.WriteString(bikeId or "")
        for _, stat in ipairs(S.Stats) do
            local top = S.Top(stat, bikeId)
            net.WriteUInt(#top, 4)
            for _, e in ipairs(top) do
                net.WriteString(e.name or "?")
                net.WriteFloat(e.v)
                net.WriteBool(e.sid == sidOf(ply))
            end
            local mine = 0
            if bikeId and bikeId ~= "" then
                mine = S.Personal(ply, stat, bikeId) or 0
            else
                for id in pairs(S.data.bikes) do
                    mine = math.max(mine, S.Personal(ply, stat, id) or 0)
                end
                for _, perBike in pairs(S.session[sidOf(ply)] or {}) do
                    mine = math.max(mine, perBike[stat] or 0)
                end
            end
            net.WriteFloat(mine)
        end
    net.Send(ply)
end
S.Send = send

net.Receive("bmx_scores_req", function(_, ply)
    if not IsValid(ply) then return end
    if CurTime() < (ply.BMXScoresNext or 0) then return end
    ply.BMXScoresNext = CurTime() + 1
    local id = net.ReadString()
    if id ~= "" and not BMX.Bikes[id] then id = "" end
    send(ply, id)
end)

concommand.Add("bmx_scores_reset", function(ply)
    if IsValid(ply) and not ply:IsSuperAdmin() then return end
    S.data, S.session = { bikes = {} }, {}
    S.Save(true)
    local m = "[BMX] scores for " .. tostring(game.GetMap()) .. " cleared"
    if IsValid(ply) then ply:ChatPrint(m) else print(m) end
end)

S.Load()
