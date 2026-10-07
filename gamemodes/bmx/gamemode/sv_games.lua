--[[--------------------------------------------------------------------------
    gamemodes/bmx/gamemode/sv_games.lua

    GAMES TO PLAY. The framework; the games themselves are small files in
    games/ (skate.lua, attack.lua, mambo.lua), each a state machine this
    file runs:

        lobby    people join; the host (or the lobby timer) begins it
        running  the game's own rules
        done     the result is shown for a few seconds, then the slot is free

        bmx_game_start skate|attack|mambo [bot]
                      open a lobby and join it. Run it again as the host to
                      begin early. "bot" seats the trick bot (SKATE only).
        bmx_game_join   bmx_game_leave   bmx_game_status

    ONE GAME AT A TIME PER SERVER. It is a deliberate limit, not an oversight:
    two games would need two sets of "who is playing", and the HUD, the chat
    and the hooks would each have to be told which. A server that wants a
    tournament runs one after the other, and BMX_GameEnded is there to chain.

    HOW A GAME HEARS ABOUT TRICKS. The same PUBLIC hooks the leaderboard uses
    (BMX_TrickLanded, BMX_ComboBanked) plus BMX_Crash for a bail. Nothing in a
    game reads a bike's internals, so every game works for every vehicle the
    registry will ever hold (G22), and a gamemode can run its own.

    WHAT COUNTS. The same rule as the scores (BMX.Scores.Counts): no bots, no
    noclip, no physgun-carried bikes. The one exception is a bot the GAME has
    invited (ply.BMXGameBot), which is how the trick bot is somebody to play.
    Its tricks never reach the leaderboard; they count here because the game
    asked for them.

    THE HUD is one generic panel (cl_games.lua) fed a snapshot the game builds
    (Game:Snapshot): a title, a clock, a message and rows. Adding a game never
    means touching the client.
----------------------------------------------------------------------------]]

BMX = BMX or {}
BMX.Games = BMX.Games or {}
local G = BMX.Games

util.AddNetworkString("bmx_game")

G.defs    = G.defs or {}     -- id -> definition { name, min, max, lateJoin, new }
G.active  = nil
G.LobbyTime  = 20            -- seconds a lobby waits before it begins (or gives up)
G.DoneTime   = 8             -- seconds a result stays on screen

local adminOnly = CreateConVar("bmx_games_admin_only", "0", bit.bor(FCVAR_ARCHIVE, FCVAR_NOTIFY, FCVAR_REPLICATED),
    "BMX: 1 = only admins may start a game (bmx_game_start); anyone may still join.")

--------------------------------------------------------------------------
-- The base every game inherits
--------------------------------------------------------------------------
local Base = {}
Base.__index = Base
G.Base = Base

function Base:Say(msg)
    for _, p in ipairs(self.players) do
        if IsValid(p) and not p:IsBot() then p:ChatPrint("[BMX " .. self.name .. "] " .. msg) end
    end
end

function Base:Has(ply)
    for _, p in ipairs(self.players) do if p == ply then return true end end
    return false
end

function Base:Join(ply)
    if self.state == "done" then return false, "that game is over" end
    if self.state == "running" and not self.def.lateJoin then return false, "it has already started" end
    if self:Has(ply) then return false, "you are already in it" end
    if #self.players >= self.def.max then return false, "it is full" end
    self.players[#self.players + 1] = ply
    self:Say(ply:Nick() .. " joined (" .. #self.players .. ")")
    if self.OnJoin then self:OnJoin(ply) end
    self.dirty = true
    return true
end

function Base:Leave(ply)
    for i, p in ipairs(self.players) do
        if p == ply then
            table.remove(self.players, i)
            if self.state ~= "done" then self:Say(ply:Nick() .. " left") end
            if self.OnLeave then self:OnLeave(ply, i) end
            self.dirty = true
            return true
        end
    end
    return false
end

-- The result: { winner = ply|nil, ranking = { { ply=, name=, text= }, ... } }
function Base:Finish(result)
    if self.state == "done" then return end
    self.state, self.doneAt, self.result = "done", CurTime(), result or {}
    self.dirty = true
    local w = self.result.winner
    self:Say(IsValid(w) and (w:Nick() .. " wins!") or "game over")
    hook.Run("BMX_GameEnded", self, self.result)
end

function Base:Begin()
    if self.state ~= "lobby" then return false, "it is not in the lobby" end
    if #self.players < self.def.min then
        return false, "needs " .. self.def.min .. " players"
    end
    self.state, self.beganAt = "running", CurTime()
    self.dirty = true
    hook.Run("BMX_GameStarted", self)
    if self.OnBegin then self:OnBegin() end
    return true
end

-- Seconds left on the clock this game shows, or nil.
function Base:Clock() return nil end

-- Subclasses add `rows`; this is the frame around them.
function Base:Snapshot()
    return {
        id = self.id, name = self.name, state = self.state,
        left = self:Clock(), msg = self.msg or "", rows = self:Rows(),
    }
end
function Base:Rows() return {} end

--------------------------------------------------------------------------
-- Registration and the running game
--------------------------------------------------------------------------
-- def = { name, min, max, lateJoin, new = function(game, opts) }. `new` fills
-- in the rules on a game that already has Base methods; it returns nothing.
function G.Register(id, def)
    def.id = id
    G.defs[id] = def
end

function G.Active() return G.active end

local function newGame(id, opts)
    local def = G.defs[id]
    if not def then return nil end
    local g = setmetatable({
        id = id, name = def.name, def = def, opts = opts or {},
        state = "lobby", players = {}, lobbyUntil = CurTime() + G.LobbyTime,
    }, { __index = function(_, k) return def.methods[k] or Base[k] end })
    return g
end

function G.Start(id, host, opts)
    if G.active and G.active.state ~= "done" then
        return nil, "a " .. G.active.name .. " game is already on (bmx_game_status)"
    end
    local g = newGame(id, opts)
    if not g then return nil, "no such game: " .. tostring(id) end
    G.active = g
    if g.OnCreate then g:OnCreate() end
    if IsValid(host) then g.host = host; g:Join(host) end
    g:Say("lobby open: bmx_game_join to play. The host runs bmx_game_start again to begin.")
    g.dirty = true
    return g
end

function G.Join(ply)
    local g = G.active
    if not g or g.state == "done" then return false, "no game to join (bmx_game_start)" end
    return g:Join(ply)
end

function G.Leave(ply)
    local g = G.active
    if not g or not g:Has(ply) then return false end
    g:Leave(ply)
    return true
end

-- Does this rider's trick count in a game? The scores' rule, with the one
-- exception: a bot the game itself invited.
function G.Counts(ply, bike)
    return BMX.Scores.Counts(ply, bike, ply.BMXGameBot == true)
end

--------------------------------------------------------------------------
-- The clock: lobby timer, each game's own Tick, the HUD, and tidying up.
--------------------------------------------------------------------------
local lastSend = 0

local function snapshotTo(g)
    local json = util.TableToJSON(g:Snapshot())
    for _, p in ipairs(g.players) do
        if IsValid(p) and not p:IsBot() then
            net.Start("bmx_game")
                net.WriteString(json)
            net.Send(p)
        end
    end
end

-- Told to leave the HUD alone: an empty snapshot clears it.
local function clearFor(ply)
    if not IsValid(ply) or ply:IsBot() then return end
    net.Start("bmx_game")
        net.WriteString("")
    net.Send(ply)
end

-- A game's slot is freed: clear every HUD, and send home any bot it invited
-- (the same tidy-up bmx_bot_remove does, for just those).
local function retire(g)
    for _, p in ipairs(g.players) do clearFor(p) end
    for _, p in ipairs(g.guests or {}) do
        if IsValid(p) and p.BMXGameBot then
            p.BMXGameBot = nil
            local b = BMX.Bot and BMX.Bot.brains[p]
            local bike = b and b.bike
            if b then BMX.Bot.Detach(b) end
            if IsValid(p) and p:IsBot() then p:Kick("BMX game over") end
            if IsValid(bike) and bike.BMXBotBike then SafeRemoveEntity(bike) end
        end
    end
    if g.OnRemove then g:OnRemove() end
    if G.active == g then G.active = nil end
end
G.Retire = retire

function G.Think()
    local g = G.active
    if not g then return end
    local now = CurTime()

    if g.state == "lobby" and now >= g.lobbyUntil then
        local ok, why = g:Begin()
        if not ok then
            g:Say("cancelled: " .. tostring(why))
            retire(g)
            return
        end
    end

    if g.state == "running" and g.Tick then g:Tick(now) end

    if g.state == "done" and now - g.doneAt >= G.DoneTime then
        retire(g)
        return
    end

    -- Once a second, and straight away when something changed.
    if g.dirty or now - lastSend >= 1 then
        g.dirty, lastSend = false, now
        snapshotTo(g)
    end
end
timer.Create("BMX.Games", 0.25, 0, G.Think)

--------------------------------------------------------------------------
-- Events from the public hooks, to the game
--------------------------------------------------------------------------
hook.Add("BMX_TrickLanded", "BMX.Games", function(ply, trick, points, bike)
    local g = G.active
    if not g or g.state ~= "running" or not g:Has(ply) or not g.OnTrick then return end
    if not G.Counts(ply, bike) then return end
    g:OnTrick(ply, trick, points, bike)
    g.dirty = true
end)

hook.Add("BMX_ComboBanked", "BMX.Games", function(ply, chain, total)
    local g = G.active
    if not g or g.state ~= "running" or not g:Has(ply) or not g.OnCombo then return end
    if not G.Counts(ply, IsValid(ply) and ply.BMXBike or nil) then return end
    g:OnCombo(ply, chain, total)
    g.dirty = true
end)

-- A crash is a bail in SKATE. BMX_Crash is the engine-side hook (bike, ply,
-- reason, severity); it may be vetoed by another listener, so this only reads.
hook.Add("BMX_Crash", "BMX.Games", function(bike, ply)
    local g = G.active
    if not g or g.state ~= "running" or not g:Has(ply) or not g.OnBail then return end
    g:OnBail(ply)
    g.dirty = true
end)

hook.Add("PlayerDisconnected", "BMX.Games", function(ply) G.Leave(ply) end)

--------------------------------------------------------------------------
-- Commands
--------------------------------------------------------------------------
local function reply(ply, msg)
    if IsValid(ply) then ply:ChatPrint("[BMX] " .. msg) else print("[BMX] " .. msg) end
end

-- A bot for SKATE: the same one bmx_bot_spawn makes, put where the host looks.
local function spawnBotFor(host)
    if not (BMX.Bot and BMX.Bot.Spawn) then return nil, "no trick bot on this server" end
    local at, yaw = Vector(0, 0, 0), 0
    if IsValid(host) then
        local tr = host:GetEyeTrace()
        if tr.Hit then at = tr.HitPos end
        yaw = host:EyeAngles().y
    end
    local b, err = BMX.Bot.Spawn(at + Vector(0, 120, 0), yaw)
    if not b then return nil, err end
    b.show = false                       -- it plays; it does not put on its show
    b.ply.BMXGameBot = true
    return b
end

concommand.Add("bmx_game_start", function(ply, _, args)
    local id = string.lower(args[1] or "")
    local g = G.active
    -- The host running it again begins the lobby early.
    if g and g.state == "lobby" and IsValid(ply) and g.host == ply and (id == "" or id == g.id) then
        local ok, why = g:Begin()
        if not ok then reply(ply, why) end
        return
    end
    if IsValid(ply) and adminOnly:GetBool() and not ply:IsAdmin() then
        reply(ply, "games are admin-only here (bmx_games_admin_only)")
        return
    end
    if not G.defs[id] then
        local names = {}
        for k in pairs(G.defs) do names[#names + 1] = k end
        table.sort(names)
        reply(ply, "usage: bmx_game_start " .. table.concat(names, "|"))
        return
    end
    -- A bot opponent is a bot spawn, so it needs the same privilege.
    if args[2] == "bot" and not BMX.Can(ply, "BMX - Bot") then
        reply(ply, "you may not seat a bot (needs the \"BMX - Bot\" privilege)")
        return
    end
    local game, err = G.Start(id, ply)
    if not game then reply(ply, err) return end
    if args[2] == "bot" then
        local b, berr = spawnBotFor(ply)
        if b then
            game.guests = { b.ply }
            game:Join(b.ply)
        else reply(ply, "no bot: " .. tostring(berr))
        end
    end
end)

concommand.Add("bmx_game_join", function(ply)
    if not IsValid(ply) then return end
    local ok, why = G.Join(ply)
    if not ok then reply(ply, why) end
end)

concommand.Add("bmx_game_leave", function(ply)
    if not IsValid(ply) then return end
    if not G.Leave(ply) then reply(ply, "you are not in a game") else clearFor(ply) end
end)

concommand.Add("bmx_game_status", function(ply)
    local g = G.active
    if not g then reply(ply, "no game is on. bmx_game_start skate|attack|mambo") return end
    local names = {}
    for _, p in ipairs(g.players) do names[#names + 1] = p:Nick() end
    reply(ply, string.format("%s (%s): %s", g.name, g.state, table.concat(names, ", ")))
    for _, r in ipairs(g:Rows()) do reply(ply, "  " .. r.name .. "  " .. (r.text or "")) end
end)

--------------------------------------------------------------------------
-- A timed game (Trick Attack, Combo Mambo): everybody scores for the same
-- clock and the biggest number wins. The two differ only in what a number is,
-- so this builds both; `score` says how an event adds to a player's total.
--------------------------------------------------------------------------
function G.Timed(id, def)
    def.methods = def.methods or {}
    local M = def.methods

    function M:OnCreate() self.totals = {} end
    function M:OnJoin(ply) self.totals[ply] = self.totals[ply] or 0 end
    function M:OnBegin()
        self.endsAt = CurTime() + def.seconds
        self.msg = "go!"
        self:Say(def.blurb .. " " .. def.seconds .. " seconds.")
    end
    function M:Clock()
        if self.state == "running" then return math.max(0, self.endsAt - CurTime()) end
        if self.state == "lobby" then return math.max(0, self.lobbyUntil - CurTime()) end
        return nil
    end
    function M:OnTrick(ply, trick, points)
        if def.onTrick then self.totals[ply] = def.onTrick(self.totals[ply] or 0, points, trick) end
    end
    function M:OnCombo(ply, chain, total)
        if def.onCombo then self.totals[ply] = def.onCombo(self.totals[ply] or 0, chain, total) end
    end
    function M:Ranking()
        local out = {}
        for _, p in ipairs(self.players) do
            out[#out + 1] = { ply = p, name = p:Nick(), v = self.totals[p] or 0 }
        end
        table.sort(out, function(a, b)
            if a.v ~= b.v then return a.v > b.v end
            return a.name < b.name
        end)
        return out
    end
    function M:Rows()
        local rows = {}
        for i, r in ipairs(self:Ranking()) do
            rows[i] = { name = r.name, text = tostring(math.floor(r.v)), hi = i == 1 and r.v > 0 }
        end
        return rows
    end
    function M:Tick(now)
        if now >= self.endsAt then
            local rank = self:Ranking()
            local top = rank[1]
            local result = { ranking = rank }
            -- Nobody scored is not a win.
            if top and top.v > 0 and not (rank[2] and rank[2].v == top.v) then result.winner = top.ply end
            self.msg = top and top.v > 0 and (top.name .. ": " .. math.floor(top.v)) or "no score"
            self:Finish(result)
        end
    end
    function M:OnLeave(ply)
        self.totals[ply] = nil
        if #self.players == 0 then self.state, self.doneAt = "done", 0 end
    end

    G.Register(id, def)
end

-- The games. After the framework so each can Register.
include("games/skate.lua")
include("games/attack.lua")
include("games/mambo.lua")
