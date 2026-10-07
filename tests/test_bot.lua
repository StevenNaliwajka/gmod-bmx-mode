--[[--------------------------------------------------------------------------
    The trick bot (sv_bot.lua), on the plant.

    The headless suite (sv_test_cases.lua, bot_*) is the authority: it rides
    each trick on real VPhysics, ramps and rails included. These ask the same
    of the shim's plant where the plant can answer -- the ground tricks ridden
    end to end, the air tricks flown from a launch state -- and check the
    parts that are plain logic: the spin pacing, the steering's sense, the
    grind approach, spawning, dressing, removing, recovering from a crash, and
    the console commands.

    Every trick is judged by the ADDON'S scoring (BMX_TricksLanded /
    BMX_ComboEnded), never by the bot's own opinion of itself.
----------------------------------------------------------------------------]]

local F = require("lib.fixture")

local TAU = 2 * math.pi

local function rig(class)
    local sv = F.server()
    local bike = F.bike(sv, class)
    local ply = F.scripted(sv, bike)
    sv:run(0.5)
    local brain = sv.env.BMX.Bot.Attach(ply, bike, { quiet = true })
    return sv, bike, ply, brain
end

local function perform(sv, brain, name, secs)
    local res
    sv.env.BMX.Bot.Perform(brain, name, function(ok, why) res = { ok = ok, why = why } end)
    sv:run(secs or 40, function() return res ~= nil end)
    return res
end

-- Airborne off a 30-degree kicker's lip, hopped: the state a launch leaves
-- the bike in (lip ~95 u up, 300 u/s forward, 360 u/s up).
local function launched(sv, bike, pitchDeg)
    local E = sv.env
    F.place(bike, E.Vector(0, 0, sv.world.groundZ + 105), E.Angle(-(pitchDeg or 26), 0, 0))
    bike:GetPhysicsObject():SetVelocity(E.Vector(300, 0, 360))
    bike.st.grounded = false
    sv:run(0.12)
end

local function performAir(sv, brain, name)
    local res
    sv.env.BMX.Bot.PerformAir(brain, name, function(ok, why) res = { ok = ok, why = why } end)
    sv:run(6, function() return res ~= nil end)
    return res
end

local function scored(brain, name)
    for _, s in ipairs(brain.scored) do if s.name == name then return s end end
end

--------------------------------------------------------------------------
-- The list
--------------------------------------------------------------------------

T.test("bot: the trick list is at least the ten core tricks, each with a routine", function()
    local sv = F.server()
    local Bot = sv.env.BMX.Bot
    T.ok(#Bot.TrickList >= 10, "at least ten: " .. #Bot.TrickList)
    for _, name in ipairs(Bot.TrickList) do
        T.ok(type(Bot.Tricks[name]) == "function", name .. " has a routine")
    end
    for _, name in ipairs({ "Backflip", "Frontflip", "Barrel Roll", "360", "Wheelie", "Stoppie",
                            "Crank Grind", "Double Peg Grind", "Combo", "Bunny Hop" }) do
        local found = false
        for _, n in ipairs(Bot.TrickList) do if n == name then found = true end end
        T.ok(found, name .. " is in the list")
    end
end)

T.test("bot: the air tricks spin the axes the scoring counts", function()
    local sv = F.server()
    local A = sv.env.BMX.Bot.AirTricks
    T.eq(A.Backflip.axis, "pitch", "backflip: pitch") T.eq(A.Backflip.sign, 1, "nose up")
    T.eq(A.Frontflip.axis, "pitch", "frontflip: pitch") T.eq(A.Frontflip.sign, -1, "nose down")
    T.eq(A["Barrel Roll"].axis, "roll", "barrel roll: roll")
    T.eq(A["360"].axis, "yaw", "360: yaw")
end)

--------------------------------------------------------------------------
-- Ground tricks, ridden end to end
--------------------------------------------------------------------------

for _, name in ipairs({ "Bunny Hop", "Wheelie", "Stoppie", "Combo" }) do
    T.test("bot: rides a " .. name .. " and lands it", function()
        local sv, bike, _, brain = rig()
        local r = perform(sv, brain, name)
        T.ok(r, "it finished")
        T.ok(r and r.ok, name .. ": " .. tostring(r and r.why))
        T.ok(sv.env.IsValid(bike:GetDriver()), "still on the bike")
        T.eq(#sv.errors, 0, "no errors: " .. table.concat(sv.errors, " | "))
    end)
end

T.test("bot: its wheelie and stoppie are the scoring's, not its own say-so", function()
    local sv, _, _, brain = rig()
    perform(sv, brain, "Wheelie")
    T.ok(scored(brain, "Wheelie"), "the scoring paid a Wheelie")
    perform(sv, brain, "Stoppie")
    T.ok(scored(brain, "Stoppie"), "and a Stoppie")
end)

T.test("bot: the combo is a landed combo of two tricks, with a bonus", function()
    local sv, bike, _, brain = rig()
    local s0 = bike:GetScore()
    perform(sv, brain, "Combo")
    local c = brain.combos[#brain.combos]
    T.ok(c and c.landed, "landed")
    T.ok(c and c.n >= 2, "of at least two tricks")
    T.ok(c and c.bonus > 0, "and paid a bonus")
    T.ok(bike:GetScore() > s0, "the bike's score went up")
end)

T.test("bot: the ground tricks work on the cruiser and the mini too", function()
    for _, class in ipairs({ "bmx_cruiser", "bmx_mini" }) do
        for _, name in ipairs({ "Bunny Hop", "Wheelie", "Stoppie" }) do
            local sv, _, _, brain = rig(class)
            local r = perform(sv, brain, name)
            T.ok(r and r.ok, class .. " " .. name .. ": " .. tostring(r and r.why))
        end
    end
end)

--------------------------------------------------------------------------
-- Air tricks, flown from a launch
--------------------------------------------------------------------------

for _, name in ipairs({ "Backflip", "Frontflip", "Barrel Roll", "360" }) do
    T.test("bot: flies a " .. name .. " off a kicker and lands on its wheels", function()
        local sv, bike, _, brain = rig()
        launched(sv, bike, (name == "Barrel Roll" or name == "360") and 15 or 26)
        local r = performAir(sv, brain, name)
        T.ok(r and r.ok, name .. ": " .. tostring(r and r.why))
        T.ok(scored(brain, name), "the scoring paid a " .. name)
        T.ok(sv.env.IsValid(bike:GetDriver()), "and the rider is still on")
    end)
end

T.test("bot: a flip is one turn, not two -- it brakes the spin once it has turned", function()
    local sv, bike, _, brain = rig()
    launched(sv, bike, 26)
    performAir(sv, brain, "Backflip")
    local s = scored(brain, "Backflip")
    T.ok(s, "a backflip")
    T.eq(s and s.count, 1, "exactly one")
end)

T.test("bot: a backflip spins nose UP and a frontflip nose DOWN", function()
    local sv, bike, _, brain = rig()
    launched(sv, bike, 26)
    performAir(sv, brain, "Backflip")
    T.ok(not scored(brain, "Frontflip"), "no frontflip from a backflip")
    sv, bike, _, brain = rig()
    launched(sv, bike, 26)
    performAir(sv, brain, "Frontflip")
    T.ok(not scored(brain, "Backflip"), "no backflip from a frontflip")
end)

T.test("bot: a 360 is a spin, not a barrel roll (RMB makes A/D yaw in the air)", function()
    local sv, bike, _, brain = rig()
    launched(sv, bike, 15)
    local worstRoll = 0
    local res
    sv.env.BMX.Bot.PerformAir(brain, "360", function(ok) res = ok end)
    sv:run(6, function()
        worstRoll = math.max(worstRoll, math.abs(bike.st.spinRoll or 0))
        return res ~= nil
    end)
    T.ok(res, "landed the 360")
    T.between(math.deg(worstRoll), 0, 45, "rolled no more than this on the way round, degrees")
end)

T.test("bot: with too little air it does not start what it cannot finish", function()
    local sv, bike, _, brain = rig()
    local E = sv.env
    -- A bunny hop's worth of air, no launch.
    F.place(bike, E.Vector(0, 0, sv.world.groundZ + 30), E.Angle(0, 0, 0))
    bike:GetPhysicsObject():SetVelocity(E.Vector(200, 0, 180))
    bike.st.grounded = false
    sv:run(0.12)
    local r = performAir(sv, brain, "Backflip")
    T.ok(r and not r.ok, "no backflip")
    T.ok(E.IsValid(bike:GetDriver()), "but it came down on its wheels rather than its head")
end)

--------------------------------------------------------------------------
-- The air controller's arithmetic
--------------------------------------------------------------------------

T.test("spin pacing: nothing left is no spin; plenty of time is gentle", function()
    local Bot = F.server().env.BMX.Bot
    T.eq(Bot.SpinPace(0, 1, 20, 15), 0, "done")
    T.eq(Bot.SpinPace(-0.3, 1, 20, 15), 0, "past it")
    T.near(Bot.SpinPace(1, 2, 20, math.huge), 1 / 2 * Bot.Config.ahead, 1e-9, "on time, a little ahead")
end)

T.test("spin pacing: never faster than can be stopped in the turn left", function()
    local Bot = F.server().env.BMX.Bot
    local r, a = 0.2, 15
    T.near(Bot.SpinPace(r, 0.01, 50, a), math.sqrt(2 * a * r), 1e-9, "the braking limit")
end)

T.test("spin pacing: never past the axis's top rate", function()
    local Bot = F.server().env.BMX.Bot
    T.eq(Bot.SpinPace(6, 0.05, 9, math.huge), 9, "capped")
end)

T.test("spin pacing: less to go or more time means slower, never faster", function()
    local Bot = F.server().env.BMX.Bot
    local last = math.huge
    for r = 6, 0.1, -0.5 do
        local w = Bot.SpinPace(r, 0.8, 20, 15)
        T.ok(w <= last + 1e-9, "monotonic in what is left at " .. r)
        last = w
    end
    T.ok(Bot.SpinPace(3, 1.2, 20, 15) <= Bot.SpinPace(3, 0.6, 20, 15), "and in time")
end)

T.test("spin input: drives toward the wanted rate, saturating, either way", function()
    local E = F.server().env
    local Bot, A = E.BMX.Bot, E.BMX.Config.Air
    T.ok(Bot.SpinInput(8, 0, A, A.pitchAccel, true) > 0, "from rest, positive for a positive want")
    T.eq(Bot.SpinInput(30, 0, A, A.pitchAccel, true), 1, "saturates")
    T.near(Bot.SpinInput(-8, 0, A, A.pitchAccel, true), -Bot.SpinInput(8, 0, A, A.pitchAccel, true), 1e-12, "symmetric")
    -- At the wanted rate, only what holds it against the damping.
    local w = 5
    local u = Bot.SpinInput(w, w, A, A.pitchAccel, true)
    T.near(u * A.pitchAccel * 1.35, (A.damping / 1.35) * w, 1e-9, "holds the rate")
end)

T.test("time to land: off the lip, a ballistic arc to the ground", function()
    local sv, bike, _, brain = rig()
    launched(sv, bike, 0)
    local t = brain:timeToLand()
    T.between(t, 0.9, 1.6, "about a second and a quarter, s")
end)

--------------------------------------------------------------------------
-- Riding sense
--------------------------------------------------------------------------

T.test("steering: a heading to the left leans left (A), to the right leans right (D)", function()
    local sv, bike, _, brain = rig()
    local yaw = bike:GetAngles().y
    T.ok(brain:steerLean(yaw + 40) < 0, "target left: lean left")
    T.ok(brain:steerLean(yaw - 40) > 0, "target right: lean right")
    T.near(brain:steerLean(yaw), 0, 0.05, "on heading: upright")
end)

T.test("steering: it rides to a point beside it and stops there", function()
    local sv, bike, _, brain = rig()
    local E = sv.env
    local target = bike:GetPos() + E.Vector(500, 400, 0)
    local done
    brain.job = coroutine.create(function() return brain:rideTo(target, 200, 60, 20) end)
    brain.jobDone = function(ok) done = ok end
    sv:run(25, function() return done ~= nil end)
    T.ok(done, "got there")
    local d = target - bike:GetPos()
    d.z = 0
    T.between(d:Length(), 0, 150, "and is near it, u")
end)

T.test("steering: it holds a line, not just a heading", function()
    local sv, bike, _, brain = rig()
    local E = sv.env
    local a = bike:GetPos() + E.Vector(0, 60, 0)              -- a line 60 u to the left
    local dir = E.Vector(1, 0, 0)
    local done
    brain.job = coroutine.create(function()
        return brain:rideLine(a, dir, 220, function(along) return along > 900 end, 10)
    end)
    brain.jobDone = function(ok) done = ok end
    sv:run(12, function() return done ~= nil end)
    T.ok(done, "rode the length of it")
    T.between(math.abs(bike:GetPos().y - a.y), 0, 15, "and ended on it, u off")
end)

--------------------------------------------------------------------------
-- Grinds: the approach is arithmetic, and the plant has no rails to test it
-- on (the headless suite rides them).
--------------------------------------------------------------------------

T.test("grind approach: the hop is pressed so the crank point comes down over the rail", function()
    local sv = F.server()
    local E, B = sv.env, sv.env.BMX
    local cfg = B.Config
    local centre, dir = E.Vector(1000, 0, 0), E.Vector(1, 0, 0)
    local press, ride, t = B.Bot.GrindApproach(cfg, centre, dir, 380, 0, 18, 600)
    T.near(ride.x, 1, 1e-9, "ridden straight along the rail")
    -- Carried on along the ride direction for t seconds at the grind speed:
    local at = press + ride * (220 * t)
    T.near(at.y, 0, 0.5, "over the rail's line")
    T.near(at.x, 1000 - 190 + 60, 0.5, "60 u along it")
end)

T.test("grind approach: a peg grind aims for the near edge, not the middle", function()
    local sv = F.server()
    local E, B = sv.env, sv.env.BMX
    local press, ride, t = B.Bot.GrindApproach(B.Config, E.Vector(0, 0, 0), E.Vector(0, 1, 0), 380, -4, 18, 600)
    local at = press + ride * (220 * t)
    T.near(at.x, 4, 0.5, "4 u right of the axis (the near edge), for a rail along +y")
end)

T.test("grind: the bot lays its rail along its run and takes it away after", function()
    local sv, bike, _, brain = rig()
    local E = sv.env
    local rail = brain:layRail("Double Peg Grind", E.Vector(800, 0, sv.world.groundZ), E.Vector(1, 0, 0))
    T.ok(E.IsValid(rail), "a rail")
    local lo, hi = rail:WorldSpaceAABB()
    T.ok(hi.x - lo.x > hi.y - lo.y, "long axis along the run")
    T.near(hi.z - sv.world.groundZ, 18, 0.5, "its top 18 u up")
    T.near((lo.x + hi.x) * 0.5, 800, 0.5, "centred where asked")
    T.ok(rail.BMXRail, "marked as the bot's")
    local res
    E.BMX.Bot.Perform(brain, "Bunny Hop", function() res = true end)
    sv:run(30, function() return res end)
    T.ok(not E.IsValid(rail), "cleared away when the trick was done")
end)

--------------------------------------------------------------------------
-- The bot player
--------------------------------------------------------------------------

local function admin(sv)
    local p = sv:player("Admin")
    p._admin = true
    p._eyeTrace = { Hit = true, HitPos = sv.env.Vector(0, 0, sv.world.groundZ), HitNormal = sv.env.Vector(0, 0, 1) }
    return p
end

local function bots(sv)
    local out = {}
    for _, p in ipairs(sv.env.player.GetAll()) do if p:IsBot() then out[#out + 1] = p end end
    return out
end

T.test("spawn: bmx_bot_spawn makes a bot called Peter Griffin, on a bike, doing the show", function()
    local sv = F.server()
    sv:command("bmx_bot_spawn", admin(sv))
    local b = bots(sv)
    T.eq(#b, 1, "one bot")
    T.eq(b[1]:Nick(), "Peter Griffin", "named by the default bmx_bot_name")
    local brain = b[1].BMXBotBrain
    T.ok(brain, "with a brain")
    T.ok(brain.show, "running the show")
    T.ok(brain.bike:GetDriver() == b[1], "on its bike")
    T.ok(b[1].BMXScripted, "driving it the scripted way, not by usercmd")
end)

T.test("spawn: bmx_bot_name and bmx_bot_model name and dress it, and the model survives a respawn", function()
    local sv = F.server()
    local E = sv.env
    E.GetConVar("bmx_bot_name"):SetString("Lois")
    E.GetConVar("bmx_bot_model"):SetString("models/petaly/peter_griffin/petergriffin.mdl")
    sv:command("bmx_bot_spawn", admin(sv))
    local p = bots(sv)[1]
    T.eq(p:Nick(), "Lois", "named")
    T.eq(p:GetModel(), "models/petaly/peter_griffin/petergriffin.mdl", "dressed")
    p:SetModel("models/player/kleiner.mdl")              -- what a respawn would do
    T.eq(E.hook.Run("PlayerSetModel", p), true, "the model hook claims it")
    T.eq(p:GetModel(), "models/petaly/peter_griffin/petergriffin.mdl", "and puts it back")
end)

T.test("spawn: a model the server does not have is refused out loud, not a broken bot", function()
    local sv = F.server()
    local E = sv.env
    sv.missingModels["models/nope/peter.mdl"] = true
    E.GetConVar("bmx_bot_model"):SetString("models/nope/peter.mdl")
    sv:command("bmx_bot_spawn", admin(sv))
    local p = bots(sv)[1]
    T.ok(p, "the bot still comes")
    T.ok(p:GetModel() ~= "models/nope/peter.mdl", "in the default model")
    T.ok(#sv.errors > 0 and sv.errors[1]:find("not mounted", 1, true), "and says why: " .. tostring(sv.errors[1]))
end)

T.test("spawn: the PlayerSetModel hook leaves other players alone", function()
    local sv = F.server()
    local p = sv:player("Human")
    T.eq(sv.env.hook.Run("PlayerSetModel", p), nil, "no opinion on a human")
end)

T.test("spawn: only an admin (or the server console) may spawn a bot", function()
    local sv = F.server()
    local nobody = sv:player("Pleb")
    nobody._eyeTrace = { Hit = true, HitPos = sv.env.Vector(0, 0, 0), HitNormal = sv.env.Vector(0, 0, 1) }
    sv:command("bmx_bot_spawn", nobody)
    T.eq(#bots(sv), 0, "refused")
    sv:command("bmx_bot_spawn", nil)
    T.eq(#bots(sv), 1, "the console may")
end)

T.test("spawn: bmx_bot_spawn cruiser puts the bot on a cruiser", function()
    local sv = F.server()
    sv:command("bmx_bot_spawn", admin(sv), "cruiser")
    local p = bots(sv)[1]
    T.eq(p.BMXBotBrain.bike:GetClass(), "bmx_cruiser", "the cruiser")
end)

T.test("remove: bmx_bot_remove kicks every bot rider and takes their bikes and ramps", function()
    local sv = F.server()
    local E = sv.env
    local a = admin(sv)
    sv:command("bmx_bot_spawn", a)
    sv:command("bmx_bot_spawn", a)
    local brains = {}
    for _, p in ipairs(bots(sv)) do brains[#brains + 1] = p.BMXBotBrain end
    local kicker = E.BMX.SpawnKicker(E.Vector(500, 0, 0), 0)
    brains[1].props[#brains[1].props + 1] = kicker
    sv:command("bmx_bot_remove", a)
    T.eq(#bots(sv), 0, "no bots")
    for _, b in ipairs(brains) do T.ok(not E.IsValid(b.bike), "its bike gone") end
    T.ok(not E.IsValid(kicker), "its kicker gone")
    T.eq(next(E.BMX.Bot.brains), nil, "no brains left running")
end)

T.test("remove: the harness's rider gets its scripted flag back when a brain lets go", function()
    local sv, _, ply, brain = rig()
    T.ok(ply.BMXScripted, "scripted while attached")
    sv.env.BMX.Bot.Detach(brain)
    T.ok(ply.BMXScripted, "and still scripted after: it was before the brain came")
    T.eq(ply.BMXBotBrain, nil, "no brain")
end)

T.test("crash: a crash mid-trick ends the trick as a miss, and the bot gets back on", function()
    local sv, bike, ply, brain = rig()
    local res
    sv.env.BMX.Bot.Perform(brain, "Wheelie", function(ok, why) res = { ok = ok, why = why } end)
    sv:run(1.5)
    bike:Crash("impact", 0.5)
    sv:run(0.2)
    T.ok(res and not res.ok and res.why == "crashed", "missed: crashed")
    sv:run(3)
    T.ok(bike:GetDriver() == ply, "back on the bike after the tumble")
end)

T.test("show: it works through the whole list, retrying a miss", function()
    local sv = F.server()
    local E = sv.env
    sv:command("bmx_bot_spawn", admin(sv))
    local brain = bots(sv)[1].BMXBotBrain
    local seen = {}
    local calls = 0
    local real = E.BMX.Bot.Perform
    E.BMX.Bot.Perform = function(b, name, done)
        calls = calls + 1
        seen[#seen + 1] = name
        -- Pretend: the first try at each misses, the second lands.
        b.job = coroutine.create(function() return (#seen % 2 == 0), "pretend" end)
        b.jobDone = function(ok, why) b.job = nil if done then done(ok, why) end end
        return true
    end
    sv:run(60, function() return #seen >= 2 * #E.BMX.Bot.TrickList end)
    E.BMX.Bot.Perform = real
    for i, name in ipairs(E.BMX.Bot.TrickList) do
        T.eq(seen[2 * i - 1], name, "try " .. name)
        T.eq(seen[2 * i], name, "and try " .. name .. " again after the miss")
    end
end)

T.test("commands: bmx_bot_trick queues a trick by name; an unknown one lists them", function()
    local sv = F.server()
    local a = admin(sv)
    sv:command("bmx_bot_spawn", a)
    local brain = bots(sv)[1].BMXBotBrain
    sv:command("bmx_bot_trick", a, "Barrel", "Roll")
    T.eq(brain.queue and brain.queue[1], "Barrel Roll", "queued first")
    a._chat = {}
    sv:command("bmx_bot_trick", a, "Nonsense Spin")
    T.ok(table.concat(a._chat, " "):find("Backflip", 1, true), "lists the tricks: " .. table.concat(a._chat, " "))
end)

T.test("commands: bmx_bot_status reports every trick", function()
    local sv, _, _, brain = rig()
    perform(sv, brain, "Wheelie")
    local lines = sv.env.BMX.Bot.Status(brain)
    local all = table.concat(lines, "\n")
    T.ok(all:find("Wheelie%s+1/1"), "the wheelie, landed once: " .. all)
    T.ok(all:find("Backflip%s+not tried"), "the rest, not tried")
end)

T.test("chat: a landed trick is announced to the humans on the server", function()
    local sv = F.server()
    local E = sv.env
    local human = sv:player("Watcher")
    local bike = F.bike(sv)
    local ply = F.scripted(sv, bike)
    sv:run(0.5)
    local brain = E.BMX.Bot.Attach(ply, bike, {})
    perform(sv, brain, "Wheelie")
    T.ok(table.concat(human._chat or {}, " "):find("landed a Wheelie", 1, true), "told: " .. table.concat(human._chat or {}, " "))
end)

--------------------------------------------------------------------------
-- What the air allows (Bot.MaxSpin), and the air change it needed
--------------------------------------------------------------------------

T.test("max spin: a bunny hop's air is not enough for a flip; a kicker's is", function()
    local E = F.server().env
    local A = E.BMX.Config.Air
    T.ok(E.BMX.Bot.MaxSpin(A, A.pitchAccel, 0.75) < 2 * math.pi, "0.75 s: no flip")
    T.ok(E.BMX.Bot.MaxSpin(A, A.pitchAccel, 1.25) > 2 * math.pi, "1.25 s: a flip")
end)

T.test("max spin: a 360 fits in a kicker's air at yawAccel 16, and did not at 4", function()
    local E = F.server().env
    local A = E.BMX.Config.Air
    T.eq(A.yawAccel, 16, "the spin's strength")
    T.ok(E.BMX.Bot.MaxSpin(A, A.yawAccel, 1.25) > 2 * math.pi, "at 16: a 360 in 1.25 s")
    T.ok(E.BMX.Bot.MaxSpin(A, 4, 1.25) < 2 * math.pi, "at the old 4: not")
end)

T.test("max spin: more air is never less spin", function()
    local E = F.server().env
    local A = E.BMX.Config.Air
    local last = -1
    for t = 0.2, 2.0, 0.1 do
        local s = E.BMX.Bot.MaxSpin(A, A.pitchAccel, t)
        T.ok(s >= last, "monotonic at " .. t)
        last = s
    end
end)

local function airborneRider()
    local sv = F.server()
    local E = sv.env
    local bike = F.bike(sv)
    F.scripted(sv, bike)
    sv:run(0.5)
    F.place(bike, E.Vector(0, 0, sv.world.groundZ + 900), E.Angle(0, 0, 0))
    bike:GetPhysicsObject():SetVelocity(E.Vector(0, 0, 0))
    bike.st.grounded = false
    sv:run(0.15)
    return sv, bike
end

T.test("air: RMB + D is a spin, with no roll", function()
    local sv, bike = airborneRider()
    F.input(bike, { lean = 1, wheelieMod = true })
    sv:run(0.6)
    T.ok(math.abs(bike.st.spinYaw) > 0.5, "it spun: " .. bike.st.spinYaw)
    T.between(math.abs(bike.st.spinRoll), 0, 0.1, "and did not roll")
end)

T.test("air: D without RMB is still a roll, with no spin", function()
    local sv, bike = airborneRider()
    F.input(bike, { lean = 1 })
    sv:run(0.6)
    T.ok(math.abs(bike.st.spinRoll) > 1, "it rolled: " .. bike.st.spinRoll)
    T.between(math.abs(bike.st.spinYaw), 0, 0.1, "and did not spin")
end)

T.test("air: RMB alone, with no A or D, does nothing in the air", function()
    local sv, bike = airborneRider()
    F.input(bike, { wheelieMod = true })
    sv:run(0.6)
    T.between(math.abs(bike.st.spinYaw), 0, 0.05, "no spin")
    T.between(math.abs(bike.st.spinRoll), 0, 0.05, "no roll")
end)

--------------------------------------------------------------------------
-- Finding room in a park (findSpot, openRun, rideTo), from the skatepark runs
--------------------------------------------------------------------------

local function job(sv, brain, fn, secs)
    local out
    brain.job = coroutine.create(function() return fn() end)
    brain.jobDone = function(a, b, c) out = { a, b, c } end
    sv:run(secs or 20, function() return out ~= nil end)
    return out
end

T.test("roam: findSpot returns the nearest place that passes the test, and says where", function()
    local sv, bike, _, brain = rig()
    local here = bike:GetPos()
    local res = job(sv, brain, function()
        return brain:findSpot(function(p) return (p - here):Length() > 550 and "yes" or nil end, "far enough")
    end)
    T.ok(res and res[1], "found one")
    local d = (res[1] - here):Length()
    T.between(d, 550, 700, "on the first ring past 550 u")
    T.eq(res[2], "yes", "with the test's answer")
    T.ok(table.concat(brain.log, "\n"):find("far enough: a spot", 1, true), "and logged it")
end)

T.test("roam: a place behind a wall is not offered (it could not be ridden to)", function()
    local E0 = F.server().env
    local sv = F.server({ solids = { { E0.Vector(150, -3000, -50), E0.Vector(170, 3000, 400) } } })
    local bike = F.bike(sv)
    local ply = F.scripted(sv, bike)
    sv:run(0.5)
    local brain = sv.env.BMX.Bot.Attach(ply, bike, { quiet = true })
    local res = job(sv, brain, function()
        return brain:findSpot(function(p) return p.x > 300 and "x" or nil end, "the far side")
    end, 30)
    T.eq(res and res[1], nil, "nowhere: everything with x > 300 is behind the wall")
end)

T.test("roam: with no run here, openRun rides to a spot that has one", function()
    local sv, bike, _, brain = rig()
    local E = sv.env
    local start = bike:GetPos()
    -- Pretend the bot's own spot is boxed in: the first look finds nothing.
    local real = brain.openRunHere
    local calls = 0
    brain.openRunHere = function(self, need)
        calls = calls + 1
        if calls == 1 then return E.Vector(1, 0, 0), 100 end
        return real(self, need)
    end
    local res = job(sv, brain, function() return brain:openRun(600) end, 40)
    T.ok(res and res[1], "a direction in the end")
    T.ok((bike:GetPos() - start):Length() > 150, "after riding somewhere else")
end)

T.test("roam: rideTo gives up when it is stuck against something, not after the whole timeout", function()
    local E0 = F.server().env
    local sv = F.server({ solids = { { E0.Vector(120, -3000, -50), E0.Vector(140, 3000, 400) } } })
    local bike = F.bike(sv)
    local ply = F.scripted(sv, bike)
    sv:run(0.5)
    local brain = sv.env.BMX.Bot.Attach(ply, bike, { quiet = true })
    local t0 = sv.world.time
    local res = job(sv, brain, function() return brain:rideTo(sv.env.Vector(800, 0, 0), 150, 50, 30) end, 35)
    T.ok(res and not res[1], "did not get there")
    T.between(sv.world.time - t0, 0, 12, "and stopped trying well before 30 s")
end)

--------------------------------------------------------------------------
-- Part spins: one turn, then hands off
--------------------------------------------------------------------------

T.test("tailwhip: one whip, then hands off -- no second whip started in the air", function()
    local sv, bike, _, brain = rig()
    launched(sv, bike, 14)
    local presses, was = 0, false
    local res = job(sv, brain, function() return brain:airPartSpin("Tailwhip", "whip", 0) end, 8)
    T.ok(res and res[1], "landed: " .. tostring(res and res[2]))
    local s = scored(brain, "Tailwhip")
    T.ok(s, "a Tailwhip paid")
    T.eq(s and s.count or 1, 1, "one")
end)

--------------------------------------------------------------------------
-- The grind hop's air: level, not steering
--------------------------------------------------------------------------

T.test("lines: in the air the line's lean is replaced by the caller's air lean, never steering", function()
    local sv, bike, _, brain = rig()
    local E = sv.env
    launched(sv, bike, 0)                       -- really in the air
    sv:run(0.1)
    local seen
    local res = job(sv, brain, function()
        return brain:rideLine(bike:GetPos() + E.Vector(0, 200, 0), E.Vector(1, 0, 0), 200, function()
            seen = bike.input.leanTarget
            return true
        end, 1, function() return { airLean = 0.37 } end)
    end, 2)
    -- The done() check runs before the input is written on the first tick,
    -- so look at what was written.
    T.near(bike.input.leanTarget, 0.37, 1e-9, "the air lean, though the line is far to the left")
    T.eq(bike.input.throttle, 0, "and no pedalling")
end)

T.test("air need: every air trick asks for the air its spin needs, a frontflip the most", function()
    local E = F.server().env
    local Bot = E.BMX.Bot
    for name in pairs(Bot.AirTricks) do
        local t = Bot.AirNeed(name)
        T.between(t, 0.8, 1.6, name .. " needs, s")
        local A = Bot.AirTricks[name]
        local Air = E.BMX.Config.Air
        T.ok(Bot.MaxSpin(Air, Air[Bot.Axes[A.axis].accel], t) >= 2 * math.pi, name .. ": and that much air is enough")
    end
    T.ok(Bot.AirNeed("Frontflip") >= Bot.AirNeed("Backflip"), "a frontflip off a nose-up lip needs at least a backflip's")
end)

T.test("air need: a ramp that gives too little air for this trick is not taken", function()
    local sv, bike, _, brain = rig()
    local E = sv.env
    local called = {}
    local real = E.BMX.FindLaunch
    E.BMX.FindLaunch = function(p, opts) called[#called + 1] = opts.config.minAir return nil, 0, "" end
    brain.allowSpawnRamp = false
    brain.needAir = 1.35
    local res = job(sv, brain, function() return brain:launch() end, 30)
    E.BMX.FindLaunch = real
    T.ok(#called > 0, "it looked")
    for _, m in ipairs(called) do T.eq(m, 1.35, "every look asked for the trick's air") end
end)

T.test("grind: a rail laid at an angle is measured by its own box, not the world's", function()
    local sv, bike, _, brain = rig()
    local E = sv.env
    local dir = E.Vector(math.cos(math.rad(30)), math.sin(math.rad(30)), 0)
    local rail = job(sv, brain, function() return brain:layRail("Double Peg Grind", E.Vector(800, 0, sv.world.groundZ), dir) end, 2)[1]
    local lo, hi = rail:WorldSpaceAABB()
    T.ok((hi.y - lo.y) > 100, "its world box is wide at 30 degrees: " .. (hi.y - lo.y))
    local mn, mx = rail:OBBMins(), rail:OBBMaxs()
    local dims = { mx.x - mn.x, mx.y - mn.y, mx.z - mn.z }
    table.sort(dims)
    T.near(dims[1], 11.8, 0.2, "but the beam itself is 11.8 wide")
end)

T.test("bot: the vert routines (G06) exist, but stay out of the trick list", function()
    local sv = F.server()
    local Bot = sv.env.BMX.Bot
    for _, name in ipairs({ "Air 180", "Spine Transfer" }) do
        T.eq(type(Bot.Tricks[name]), "function", name .. " has a routine")
        for _, t in ipairs(Bot.TrickList or {}) do T.ok(t ~= name, name .. " is asked for by name, not picked") end
    end
end)

T.test("air: a trick that only just fits on paper is not started (it needs 6% in hand)", function()
    local sv, bike, _, brain = rig()
    local E = sv.env
    launched(sv, bike, 14)
    local real = E.BMX.Bot.MaxSpin
    -- What the air allows: 3% more than the target -- enough on paper.
    E.BMX.Bot.MaxSpin = function() return (2 * math.pi + E.BMX.Bot.Config.margin) * 1.03 end
    local r = performAir(sv, brain, "Backflip")
    E.BMX.Bot.MaxSpin = real
    T.ok(r and not r.ok and r.why == "not enough air", "refused: " .. tostring(r and r.why))
    T.ok(E.IsValid(bike:GetDriver()), "and came down on its wheels")
end)

--------------------------------------------------------------------------
-- Stuck
--------------------------------------------------------------------------

local function flat(a, b) local d = a - b return math.sqrt(d.x * d.x + d.y * d.y) end

T.test("bot: stuck mid-trick, it gives the trick up and gets itself out by bouncing or backing up", function()
    local sv, bike, ply, b = rig()
    local E, Bot = sv.env, sv.env.BMX.Bot
    Bot.Tricks["Test Stall"] = function(br) while true do br:set({}) coroutine.yield() end end
    local t0 = sv.world.time
    local res = perform(sv, b, "Test Stall", 20)
    Bot.Tricks["Test Stall"] = nil
    T.ok(res and not res.ok and tostring(res.why):find("stuck", 1, true), "the trick ends as stuck: " .. tostring(res and res.why))
    T.ok(sv.world.time - t0 >= Bot.Config.stuckEscape, "not before stuckEscape")
    T.ok(sv.world.time - t0 < Bot.Config.stuckEscape + 1, "and soon after it")
    local stall = b.escape and b.escape.from
    T.ok(stall, "an escape is under way")
    sv:run(Bot.Config.stuckTime, function() return b.escape == nil end)
    T.ok(b.escape == nil, "and it ends")
    T.ok((b.escaped or 0) + (b.unstuck or 0) == 1, "by getting out or by the reset, once")
    T.ok(flat(bike:GetPos(), stall) > Bot.Config.stuckMove, "clear of the stall spot")
    T.ok(b:riding(), "still riding")
end)

T.test("bot: the escape bounces (a hop) first, then backs the bike up", function()
    local sv, bike, ply, b = rig()
    local Bot = sv.env.BMX.Bot
    b:startEscape("test")
    T.eq(Bot.EscapeMoves[1].name, "bounce", "first a bounce")
    T.eq(Bot.EscapeMoves[2].name, "back up", "then backing up")
    local hopped = false
    for _ = 1, 40 do
        if bike.hopRelease or bike.hopHeld then hopped = true end
        if not b.escape then break end
        sv:run(0.05)
    end
    T.ok(hopped, "the bounce is a real hop")
end)

T.test("bot: put back on open ground, upright and still, riding", function()
    local sv, bike, ply, b = rig()
    local E = sv.env
    local home = b.home
    F.place(bike, home + E.Vector(300, 0, 0), E.Angle(0, 90, 40))
    b:unstick("test")
    T.ok(flat(bike:GetPos(), home) < 1, "at its home")
    T.ok(math.abs(bike:GetAngles().r) < 1, "upright")
    T.eq(b.unstuck, 1, "counted")
    sv:run(0.5)
    T.ok(b:riding(), "riding")
end)

T.test("bot: standing still with nothing to do is not stuck", function()
    local sv, bike, ply, b = rig()
    sv:run(30)
    T.eq(b.unstuck or 0, 0, "never reset")
    T.ok(b.escape == nil, "never escaping")
end)

T.test("bot: a bike fallen out of the world is put back at once", function()
    local sv, bike, ply, b = rig()
    local E = sv.env
    local home = b.home
    F.place(bike, home - E.Vector(0, 0, sv.env.BMX.Bot.Config.stuckFall + 500), E.Angle(0, 0, 0))
    b:watchStuck()
    T.eq(b.unstuck, 1, "reset")
    T.ok(math.abs(bike:GetPos().z - home.z) < 40, "back up at home height: " .. bike:GetPos().z)
end)
