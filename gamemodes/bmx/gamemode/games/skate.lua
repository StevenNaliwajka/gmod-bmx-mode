--[[--------------------------------------------------------------------------
    gamemodes/bmx/gamemode/games/skate.lua

    SKATE (HORSE, with a different word): 2-8 players take turns.

        SET     the setter lands a trick. Whatever they land first becomes the
                trick to beat. If they bail or run out of time they set nothing,
                it passes on, and nobody gets a letter: a setter is not
                punished for being ambitious.
        FOLLOW  every other player, in order, gets ONE attempt to land the SAME
                trick (same trick id; the bike does not matter). Land it and
                you are safe. Bail, or run out of time, and you get a letter.
        ...and the next player in the order sets.

    Spell the whole word and you are out; the last one standing wins.

    "THE SAME TRICK" IS THE TRICK'S ID, which is its scoring name lower-cased
    ("backflip", "crank grind"), or the id a trick registered with once
    BMX.RegisterTrick exists. A rider who does the right trick and lands some
    OTHER trick first is not penalised: only a bail or the clock fails an
    attempt, so a follower can keep trying inside their time. The count has to
    match or beat: setting a double backflip needs two.

    "AIR TIME" CANNOT BE CALLED. It is paid on top of nearly every flip, so as
    the set it would mean "whatever the setter did"; it is ignored as a set,
    and a follower's flip still has to be the called one.

    THE BOT. A bot the game invited plays by the same rules. On its turn to set
    it picks a trick from the list it knows (BMX.Bot.TrickList) and rides off
    to do it; on its turn to follow it does the called one if it has it. If it
    does not, the clock gives it the letter, which is also what a human gets.
----------------------------------------------------------------------------]]

local G = BMX.Games

local LETTERS  = "SKATE"
local SET_TIME = 45        -- seconds the setter has to land something
local TRY_TIME = 30        -- seconds each follower has

-- What the bot may set: the tricks that are not a lottery on a bad map.
local BOT_SETS = { "Backflip", "Frontflip", "Barrel Roll", "360", "Wheelie",
                   "Stoppie", "Crank Grind", "Double Peg Grind" }

local function idOf(trick)
    return trick.id or string.lower(trick.name or "")
end

local M = {}

function M:OnCreate()
    local o = self.opts
    self.letters = o.letters or LETTERS
    self.setTime = o.setTime or SET_TIME
    self.tryTime = o.tryTime or TRY_TIME
    self.owed    = {}        -- [ply] = letters so far
    self.phase   = "set"
    self.queue   = {}        -- followers still to attempt, in order
    self.target  = nil       -- { id, name, count }
end

function M:Alive()
    local out = {}
    for _, p in ipairs(self.players) do
        if (self.owed[p] or 0) < #self.letters then out[#out + 1] = p end
    end
    return out
end

function M:Word(ply)
    return string.sub(self.letters, 1, self.owed[ply] or 0)
end

-- The player after `ply` in join order who is still in, wrapping round. `ply`
-- need not be in the game any more (a setter who just left).
function M:NextAfter(ply)
    local n = #self.players
    local at = 0
    for i, p in ipairs(self.players) do if p == ply then at = i end end
    for k = 1, n do
        local p = self.players[(at + k - 1) % n + 1]
        if p ~= nil and (self.owed[p] or 0) < #self.letters then return p end
    end
end

-- Hand a bot its turn. It only ever DOES something here; scoring (the tricks
-- it lands) comes back through the same hooks a human's do.
local function drive(ply, name)
    local b = ply.BMXGameBot and BMX.Bot and BMX.Bot.brains[ply]
    if not b or b.job or not name or not BMX.Bot.Tricks[name] then return end
    BMX.Bot.Perform(b, name, nil)
end

local function botNameFor(id)
    for _, n in ipairs(BMX.Bot and BMX.Bot.TrickList or {}) do
        if string.lower(n) == id then return n end
    end
end

function M:StartSet(setter)
    self.phase, self.setter, self.target, self.queue = "set", setter, nil, {}
    self.turnEnds = CurTime() + self.setTime
    self.msg = setter:Nick() .. " sets a trick"
    self:Say(self.msg)
    if setter.BMXGameBot and BMX.Bot then
        drive(setter, BOT_SETS[math.random(#BOT_SETS)])
    end
end

function M:StartFollow()
    self.phase = "follow"
    self.queue = {}
    local p = self.setter
    for _ = 1, #self.players do
        p = self:NextAfter(p)
        if not p or p == self.setter then break end
        self.queue[#self.queue + 1] = p
    end
    self:NextFollower()
end

function M:NextFollower()
    local nxt = table.remove(self.queue, 1)
    if not nxt then return self:EndRound() end
    self.current = nxt
    self.turnEnds = CurTime() + self.tryTime
    self.msg = nxt:Nick() .. " must land the " .. self.target.name
    self:Say(self.msg)
    if nxt.BMXGameBot then drive(nxt, botNameFor(self.target.id)) end
end

-- Everyone has had their go: the next player in the order sets.
function M:EndRound()
    if #self:Alive() <= 1 then return self:Conclude() end
    self:StartSet(self:NextAfter(self.setter) or self:Alive()[1])
end

function M:Conclude()
    local alive = self:Alive()
    local rank = {}
    for _, p in ipairs(self.players) do
        rank[#rank + 1] = { ply = p, name = p:Nick(), text = self:Word(p) }
    end
    local winner = #alive == 1 and alive[1] or nil
    self.msg = winner and (winner:Nick() .. " is the last one standing") or "nobody is left"
    self:Finish({ winner = winner, ranking = rank })
end

function M:GiveLetter(ply, why)
    self.owed[ply] = (self.owed[ply] or 0) + 1
    local word = self:Word(ply)
    local out = self.owed[ply] >= #self.letters
    self:Say(ply:Nick() .. " " .. why .. ": " .. word .. (out and "  -- OUT" or ""))
    hook.Run("BMX_GameLetter", self, ply, word, out)
end

function M:OnBegin()
    self.owed = {}
    self:StartSet(self.players[1])
end

function M:OnTrick(ply, trick, points)
    if self.phase == "set" and ply == self.setter then
        if idOf(trick) == "air time" then return end
        self.target = { id = idOf(trick), name = trick.name, count = trick.count or 1 }
        if self.target.count > 1 then self.target.name = self.target.count .. "x " .. trick.name end
        self:Say(ply:Nick() .. " set the " .. self.target.name)
        self:StartFollow()
    elseif self.phase == "follow" and ply == self.current then
        if idOf(trick) == self.target.id and (trick.count or 1) >= self.target.count then
            self:Say(ply:Nick() .. " landed it")
            self:NextFollower()
        end
    end
end

-- A bail ends an attempt; for the setter it ends the turn with no letter.
function M:OnBail(ply)
    if self.phase == "set" and ply == self.setter then
        self:Say(ply:Nick() .. " bailed the set; it passes")
        self:EndRound()
    elseif self.phase == "follow" and ply == self.current then
        self:GiveLetter(ply, "bailed")
        self:NextFollower()
    end
end

function M:Tick(now)
    if now < (self.turnEnds or math.huge) then return end
    if self.phase == "set" then
        self:Say(self.setter:Nick() .. " ran out of time to set; it passes")
        self:EndRound()
    elseif self.phase == "follow" then
        self:GiveLetter(self.current, "ran out of time")
        self:NextFollower()
    end
end

function M:OnLeave(ply)
    self.owed[ply] = nil
    if self.state == "lobby" then
        if #self.players == 0 then self.state, self.doneAt = "done", 0 end
        return
    end
    if self.state ~= "running" then return end
    if #self.players < 2 then return self:Conclude() end
    if ply == self.setter then
        -- Their turn passes, as if they had bailed the set.
        self:StartSet(self:Alive()[1])
    elseif ply == self.current then
        self:NextFollower()
    else
        for i, p in ipairs(self.queue) do if p == ply then table.remove(self.queue, i) break end end
    end
end

function M:Clock()
    if self.state == "lobby" then return math.max(0, self.lobbyUntil - CurTime()) end
    if self.state == "running" and self.turnEnds then return math.max(0, self.turnEnds - CurTime()) end
end

function M:Rows()
    local rows = {}
    for _, p in ipairs(self.players) do
        local out = (self.owed[p] or 0) >= #self.letters
        local role, hi = "", false
        if self.state == "running" and not out then
            if self.phase == "set" and p == self.setter then role, hi = " (setting)", true
            elseif self.phase == "follow" and p == self.current then role, hi = " (up)", true end
        end
        rows[#rows + 1] = { name = p:Nick(), text = self:Word(p) .. role, out = out, hi = hi }
    end
    return rows
end

G.Register("skate", { name = "SKATE", min = 2, max = 8, methods = M })
