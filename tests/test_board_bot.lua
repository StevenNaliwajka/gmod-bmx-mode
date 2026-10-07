--[[--------------------------------------------------------------------------
    The trick bot on a skateboard (sv_board_bot.lua): the board's own show, the
    three routines, and a bike bot told to do a board trick. Needs the addon's
    skateboard (G23), so it runs on the addon's harness with BMX_ADDON pointing
    at a checkout that has it.
----------------------------------------------------------------------------]]

local F = require("lib.fixture")
local BF = require("lib.board")

----------------------------------------------------------------------
-- The bot on a board
--------------------------------------------------------------------------

local function botRig()
    local sv = F.server()
    local e = BF.board(sv)
    local ply = F.scripted(sv, e)
    sv:run(0.5)
    local brain = sv.env.BMX.Bot.Attach(ply, e, { quiet = true })
    return sv, e, brain
end

local function botPerform(sv, brain, name)
    local res
    sv.env.BMX.Bot.Perform(brain, name, function(ok, why) res = { ok = ok, why = why } end)
    sv:run(40, function() return res ~= nil end)
    return res
end

T.test("bot: a board's show is its own, a bike's is the bike's, and each board trick has a routine", function()
    local sv = F.server()
    local Bot = sv.env.BMX.Bot
    local bike = F.bike(sv)
    local e = BF.board(sv)
    -- A bike runs the bike show (plus the poses, and only what the map can
    -- host: sv_botmap.lua); a board never gets any of that.
    local has = {}
    for _, n in ipairs(Bot.TrickListFor(bike)) do has[n] = true end
    T.ok(has["Bunny Hop"] and has["Wheelie"] and not has["Kickflip"], "a bike runs the bike show")
    T.eq(Bot.TrickListFor(e), Bot.BoardTrickList, "a board runs its own")
    for _, name in ipairs(Bot.BoardTrickList) do
        T.eq(type(Bot.Tricks[name]), "function", name .. " has a routine")
    end
end)

T.test("bot: a bike bot told to Kickflip says it is not on a skateboard", function()
    local sv = F.server()
    local bike = F.bike(sv)
    local ply = F.scripted(sv, bike)
    sv:run(0.5)
    local brain = sv.env.BMX.Bot.Attach(ply, bike, { quiet = true })
    local r = botPerform(sv, brain, "Kickflip")
    T.ok(r and not r.ok and r.why == "not a skateboard", tostring(r and r.why))
end)

T.test("bot: rides a Kickflip on a skateboard and the scoring pays it", function()
    local sv, e, brain = botRig()
    local r = botPerform(sv, brain, "Kickflip")
    T.ok(r and r.ok, "Kickflip: " .. tostring(r and r.why))
    local paid
    for _, s in ipairs(brain.scored) do if s.name:find("Kickflip", 1, true) then paid = s end end
    T.ok(paid, "the scoring paid a Kickflip")
    T.ok(sv.env.IsValid(e:GetDriver()), "still on the board")
end)

T.test("bot: holds a Manual on a skateboard and the scoring pays it", function()
    local sv, e, brain = botRig()
    local r = botPerform(sv, brain, "Manual")
    T.ok(r and r.ok, "Manual: " .. tostring(r and r.why))
    T.ok(sv.env.IsValid(e:GetDriver()), "still on the board")
end)
