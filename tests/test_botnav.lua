--[[--------------------------------------------------------------------------
    The trick bot on the addon's navmesh (sv_botnav.lua) and its picture
    (sv_botavatar.lua, cl_botavatar.lua).

    The routing itself needs a mesh and a map and is checked on a real server;
    here: the launch it learns to stop using, and that the picture is offered
    to the clients when the bot joins.
----------------------------------------------------------------------------]]

local F = require("lib.fixture")

local function env()
    local sv = F.server()
    return sv.env, sv
end

T.test("bot: a launch it has missed off sinks below one it has landed off", function()
    local E = env()
    local Bot = E.BMX.Bot
    T.ok(Bot.LaunchScore, "loaded")
    local function L(x) return { lip = E.Vector(x, 0, 100), height = 100, angle = math.rad(22) } end
    local a, b = L(0), L(1000)
    local s0 = Bot.LaunchScore(a)
    T.eq(Bot.LaunchScore(b), s0, "the same ramp twice scores the same")
    local function key(l) return string.format("%d,%d", math.floor(l.lip.x / 64), math.floor(l.lip.y / 64)) end
    Bot.LaunchOutcome(key(a), false, "not enough air")
    Bot.LaunchOutcome(key(b), true)
    T.ok(Bot.LaunchScore(b) > s0 and Bot.LaunchScore(a) < s0, "landed up, missed down")
    T.ok(not Bot.LaunchUsable(a), "one miss and no landing drops it")
    T.ok(Bot.LaunchUsable(b), "a landing keeps it")
    T.ok(not Bot.LaunchUsable({ lip = E.Vector(5000, 0, 50), height = 50, angle = math.rad(15) }), "50 u is not a flip's worth")
    Bot.LaunchOutcome(key(b), false, "crashed")
    T.ok(Bot.LaunchScore(b) > s0, "a crash is the rider, not the ramp")
end)

-- Live Petopia, 2026-10-17: "bot trick failed: sv_botnav.lua:189: attempt to call
-- method 'GetCenter' (a nil value)". For a spot off the mesh Nav.Path answers nil
-- and a reason, and pickByPath took the reason for the list of areas (GMod indexes
-- a string by number: its "areas" were the reason's letters). The trick failed.
T.test("bot: a spot off the mesh is passed over when choosing where to go, not a failed trick", function()
    local E, sv = env()
    local Bot, Nav = E.BMX.Bot, E.BMX.Nav
    local bike = F.bike(sv)
    local ply = F.scripted(sv, bike)
    sv:run(0.5)
    local b = Bot.Attach(ply, bike, { quiet = true })
    local function area(x) return { GetCenter = function() return E.Vector(x, 0, 0) end } end
    local real = Nav.Path
    Nav.Path = function(from, to)
        if to.x > 500 then return nil, "off the mesh" end
        return { from, to }, { area(from.x), area(to.x) }
    end
    local far, near = { x = 1000, s = 100 }, { x = 200, s = 10 }
    local ok, best = pcall(b.pickByPath, b, { far, near }, function(it) return it.s end,
        function(it) return E.Vector(it.x, 0, 0) end)
    Nav.Path = real
    T.ok(ok, "no error: " .. tostring(best))
    T.ok(best == near, "the spot it can get to, though the other scores more")
end)
