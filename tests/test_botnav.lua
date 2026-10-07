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
