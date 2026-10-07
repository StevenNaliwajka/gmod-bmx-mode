--[[--------------------------------------------------------------------------
    sv_board_bot.lua

    THE BOT ON A SKATEBOARD (G23): bmx_bot_spawn skateboard, then bmx_bot_trick
    Kickflip, Manual or "50-50 Grind". The bot is sv_bot.lua's, and so are the
    riding helpers (rideLine, pace, openRun, layRail); this file adds three tricks
    that write the board's input record (BMX.Board.InputOf) the way a player's keys
    would, and the list a board's show runs in. A bike bot's list is unchanged.

    THESE ARE WRITTEN FROM THE PLANT, NOT PROVED ON A SERVER, like the other
    unrun headless cases: the kickflip and the manual ride the same code the
    offline suite rides (tests/test_board_flips.lua, test_board_grind.lua); the
    50-50 has to find a rail by timing a pop over it, which is the part to watch
    on the first live run (`bmx_bot_status` says what each one managed).
----------------------------------------------------------------------------]]

BMX = BMX or {}

-- This file lives in the gamemode (the bot does), and the skateboard lives in
-- the addon: an addon without G23, or a load order without the bot, loads
-- nothing here rather than erroring.
if not (BMX.Bot and BMX.Bot.Tricks and BMX.Board and BMX.Board.InputOf) then return end

local Bot = BMX.Bot
local B = BMX.Board
local T = Bot.Tricks

Bot.BoardTrickList = { "Kickflip", "Manual", "50-50 Grind" }

function Bot.TrickListFor(bike)
    if B.IsBoard and B.IsBoard(bike) then return Bot.BoardTrickList end
    return Bot.TrickList
end

local function tick() coroutine.yield() end

-- The board's own keys, on top of the standard fields Brain:set writes.
local function board(b, t)
    t = t or {}
    local bi = B.InputOf(b.bike.input)
    bi.fwd, bi.side = t.fwd or 0, t.side or 0
    bi.w, bi.s = t.w or false, t.s or false
    bi.jump, bi.alt, bi.grab = t.jump or false, t.alt or false, t.grab or false
    bi.duck, bi.swap = false, false
    bi.flickF, bi.flickS = 0, 0
end

local function paidLike(b, t0, word)
    for _, s in ipairs(b.scored) do
        if s.t >= t0 and s.name:find(word, 1, true) then return s end
    end
end

local function isBoard(b) return B.IsBoard and B.IsBoard(b.bike) end

-- Up to `speed` along a clear run, returns the direction.
local function rollUp(b, speed)
    local dir, len = b:openRun(700)
    if not dir or len < 500 then return nil, "no room" end
    local ok, why = b:rideLine(b.bike:GetPos(), dir, speed, function() return b:speed() >= speed - 8 end, 10)
    if not ok then return nil, why end
    return dir
end

T["Kickflip"] = function(b)
    if not isBoard(b) then return false, "not a skateboard" end
    local dir, why = rollUp(b, 110)
    if not dir then return false, why end
    local t0 = CurTime()
    -- Crouch for a full pop while rolling, then release with A held.
    local t = CurTime()
    while CurTime() - t < B.Tune.crouchMax + 0.05 do
        if not b:riding() then return false, "off the bike" end
        b:set({})
        board(b, { jump = true })
        tick()
    end
    board(b, { side = -1 })
    b:set({})
    local tf = CurTime()
    while CurTime() - tf < 1.0 do
        if not b:riding() then return false, "off the bike" end
        board(b, { side = CurTime() - tf < 0.2 and -1 or 0 })
        tick()
    end
    board(b, {})
    b:waitLanded(0.4, 3)
    if paidLike(b, t0, "Kickflip") and b:riding() then return true end
    return false, "no kickflip scored"
end

T["Manual"] = function(b)
    if not isBoard(b) then return false, "not a skateboard" end
    local dir, why = rollUp(b, 100)
    if not dir then return false, why end
    local t0, t = CurTime(), CurTime()
    while CurTime() - t < 2.2 do
        if not b:riding() then return false, "off the bike" end
        local m = b:st().board and b:st().board.meter or 0
        b:set({})
        -- W lowers the meter, S raises it (a manual).
        board(b, { grab = true, w = m > 0.1, s = m < -0.1, fwd = m > 0.1 and 1 or (m < -0.1 and -1 or 0) })
        tick()
    end
    board(b, {})
    b:waitLanded(0.4, 3)
    if paidLike(b, t0, "Manual") and b:riding() then return true end
    return false, "no manual scored"
end

T["50-50 Grind"] = function(b)
    if not isBoard(b) then return false, "not a skateboard" end
    local dir, len = b:openRun(1100)
    if not dir or len < 900 then return false, "no room" end
    local start = b.bike:GetPos()
    local ground = start - Vector(0, 0, BMX.RestHeight(b.bike:Cfg()))
    local e = b:layRail("Crank Grind", ground + dir * 700, dir)
    if not e then return false, "could not lay a rail" end
    local lo, hi = Bot.RailBounds(e)
    local railStart = (lo + hi) * 0.5 - dir * (math.abs((hi - lo):Dot(dir)) * 0.5)
    local speed = 170
    local t0 = CurTime()
    local pressed, armed = nil, false
    local ok, why = b:rideLine(start, dir, speed, function(along)
        if b:st().grind then return true end
        local rel = b.bike:GetPos() - railStart
        local toRail = -rel:Dot(dir)                       -- units before the rail starts
        -- Release a full crouch about a third of a second of travel before it.
        if not pressed and toRail < b:speed() * 0.36 + 12 then pressed = CurTime() return true end
        return false
    end, 12)
    -- The approach above only rolls; the pop and the arm are driven here, on the
    -- clock, from the moment `pressed` was set.
    local tp = CurTime()
    while b:riding() and not b:st().grind and CurTime() - tp < 3 do
        local dt = CurTime() - (pressed or tp)
        if not pressed then pressed = CurTime() end
        b:set({ throttle = 0.15 })
        if dt < 0.1 then board(b, { jump = true })          -- the crouch
        elseif dt < 0.2 then board(b, {})                   -- the pop
        else board(b, { jump = true }) end                  -- armed: SPACE in the air
        tick()
    end
    local tg = CurTime()
    while b:st().grind and CurTime() - tg < 6 do
        local m = b:st().board and b:st().board.meter or 0
        b:set({})
        board(b, { jump = true, side = m > 0.1 and -1 or (m < -0.1 and 1 or 0) })
        tick()
    end
    board(b, {})
    b:waitLanded(0.5, 3)
    if paidLike(b, t0, "50-50") and b:riding() then return true end
    return false, why or "no 50-50 scored"
end
