--[[--------------------------------------------------------------------------
    The trick bot on the map as it is (sv_botmap.lua, and bmx_bot_props in
    sv_bot.lua): it puts nothing down of its own unless a server says so,
    finds the map's ramp faces and ledges, and runs the show the map can host.

    The finders' geometry on a real map (petopia_bmx_fall: eight funbox faces,
    seven planting-bed kerbs) is checked on a real server; here: the rules.
----------------------------------------------------------------------------]]

local F = require("lib.fixture")

local function rig(opts)
    local sv = F.server(opts)
    local bike = F.bike(sv)
    local ply = F.scripted(sv, bike)
    sv:run(0.5)
    local brain = sv.env.BMX.Bot.Attach(ply, bike, { quiet = true })
    return sv, bike, ply, brain
end

local function perform(sv, brain, name, secs)
    local res
    sv.env.BMX.Bot.Perform(brain, name, function(ok, why) res = { ok = ok, why = why } end)
    sv:run(secs or 60, function() return res ~= nil end)
    return res
end

--------------------------------------------------------------------------
-- Nothing of its own
--------------------------------------------------------------------------
T.test("botmap: by default the bot puts nothing down (bmx_bot_props 0); 1 or the caller lets it", function()
    local sv = F.server()
    local E = sv.env
    T.eq(E.GetConVar("bmx_bot_props"):GetString(), "0", "off by default")
    local bike = F.bike(sv)
    local ply = F.scripted(sv, bike)
    local b = E.BMX.Bot.Attach(ply, bike, { quiet = true })
    T.eq(b.allowSpawnRamp, false, "a bot attached with no say: nothing of its own")
    E.BMX.Bot.Detach(b)
    E.GetConVar("bmx_bot_props"):SetString("1")
    b = E.BMX.Bot.Attach(ply, bike, { quiet = true })
    T.eq(b.allowSpawnRamp, true, "bmx_bot_props 1: it may")
    E.BMX.Bot.Detach(b)
    E.GetConVar("bmx_bot_props"):SetString("0")
    b = E.BMX.Bot.Attach(ply, bike, { quiet = true, allowSpawnRamp = true })
    T.eq(b.allowSpawnRamp, true, "a caller that asks (the headless cases) still may")
end)

T.test("botmap: on a map with nothing to jump or grind, an air trick and a grind put nothing down and miss", function()
    local sv, bike, _, brain = rig()
    local E = sv.env
    local kickers, rails = 0, 0
    local realK = E.BMX.SpawnKicker
    E.BMX.SpawnKicker = function(...) kickers = kickers + 1 return realK(...) end
    local realR = brain.layRail
    brain.layRail = function(...) rails = rails + 1 return realR(...) end
    local r = perform(sv, brain, "Tailwhip")
    T.ok(r and not r.ok, "the tailwhip is a miss: " .. tostring(r and r.why))
    local g = perform(sv, brain, "Double Peg Grind")
    T.ok(g and not g.ok, "the grind is a miss: " .. tostring(g and g.why))
    T.eq(kickers, 0, "no kicker put down")
    T.eq(rails, 0, "no rail laid")
    T.eq(#brain.props, 0, "nothing of its own in the world")
    T.eq(#E.ents.FindByClass("prop_physics"), 0, "and no prop anywhere")
end)

--------------------------------------------------------------------------
-- Ramp faces: a profile read uphill
--------------------------------------------------------------------------
-- A profile: `flat` samples at 0, then a climb of `rise` per sample to
-- `height`, then `deck` flat samples, then `after`.
local function prof(flat, rise, height, deck, after)
    local zs, z = {}, 0
    for _ = 1, flat do zs[#zs + 1] = 0 end
    while z < height do z = math.min(height, z + rise) zs[#zs + 1] = z end
    for _ = 1, deck do zs[#zs + 1] = height end
    for _, v in ipairs(after) do zs[#zs + 1] = v end
    return zs, flat + 3
end

T.test("botmap: a funbox's side is a face: a climb to a deck that slopes back down", function()
    local sv = F.server()
    local M = sv.env.BMX.Bot.Map
    local down = {}
    for z = 86, 0, -5 do down[#down + 1] = z end
    for _ = 1, 10 do down[#down + 1] = 0 end
    local zs, at = prof(20, 5, 86, 30, down)
    local f = M.ReadFace(zs, at, 8)
    T.ok(f, "a face")
    T.eq(f.height, 86, "86 u high")
    T.eq(f.roll, "slope", "and a way back down off the deck")
    T.between(f.deck, 230, 250, "a deck of about 240 u")
end)

T.test("botmap: a kicker (a lip that drops), a table against a wall and a quarter pipe are not faces", function()
    local sv = F.server()
    local M = sv.env.BMX.Bot.Map
    local zs, at = prof(20, 5, 86, 0, { 0, 0, 0, 0, 0 })
    local f = M.ReadFace(zs, at, 8)
    T.ok(not f or f.deck < 96, "a kicker has no deck to land on")
    zs, at = prof(20, 5, 113, 12, { 200, 300, 400 })
    f = M.ReadFace(zs, at, 8)
    T.ok(f and f.roll == "wall", "a deck that ends in a wall: no way off it")
    zs, at = prof(20, 5, 113, 30, { 0, 0, 0, 0 })
    f = M.ReadFace(zs, at, 8)
    T.ok(f and f.roll == "drop", "a deck that ends in a 113 u drop is a drop, not a roll-off")
    -- A quarter pipe steepens until it is a wall.
    local q, z = {}, 0
    for _ = 1, 20 do q[#q + 1] = 0 end
    for i = 1, 30 do z = z + i * 0.8 q[#q + 1] = z end
    f = M.ReadFace(q, 24, 8)
    T.eq(f, nil, "a quarter pipe steepens into a wall")
end)

--------------------------------------------------------------------------
-- Ledges
--------------------------------------------------------------------------
local function bedWorld(h)
    local E0 = F.server().env
    return { solids = { { E0.Vector(-1200, 200, -64), E0.Vector(1200, 288, h) } } }
end

T.test("botmap: a 20 u kerb beside the floor is a ledge; its edge and top are found", function()
    local sv = F.server(bedWorld(20))
    local E, M = sv.env, sv.env.BMX.Bot.Map
    local gz = sv.world.groundZ
    local e, top = M.LedgeAt(E.Vector(0, 170, gz), E.Vector(0, 1, 0))
    T.ok(e, "a ledge")
    T.near(top, 20, 0.5, "its top")
    T.near(e.y, 200, 1.5, "its edge, at the kerb's face")
end)

T.test("botmap: a wall, or a box no hop reaches, is not a ledge", function()
    local sv = F.server(bedWorld(60))
    local E, M = sv.env, sv.env.BMX.Bot.Map
    T.eq(M.LedgeAt(E.Vector(0, 170, sv.world.groundZ), E.Vector(0, 1, 0)), nil, "60 u up: out of a hop's reach")
    T.eq(M.LedgeAt(E.Vector(0, -300, sv.world.groundZ), E.Vector(0, 1, 0)), nil, "nothing within reach: no ledge")
end)

T.test("botmap: edge samples join into one ledge per edge, ridden with the top on the left", function()
    local sv = F.server()
    local E, M = sv.env, sv.env.BMX.Bot.Map
    local s = {}
    for x = -600, 600, 24 do s[#s + 1] = { pos = E.Vector(x, 200, 20), side = E.Vector(0, 1, 0) } end
    for x = 900, 1000, 24 do s[#s + 1] = { pos = E.Vector(x, 200, 20), side = E.Vector(0, 1, 0) } end
    local L = M.JoinLedges(s, 60, 240)
    T.eq(#L, 1, "one ledge: the 100 u stub past the gap is too short")
    T.near(L[1].len, 1200, 1, "1200 u of it")
    local left = E.Vector(-L[1].dir.y, L[1].dir.x, 0)
    T.ok(left:Dot(L[1].side) > 0.99, "ridden along it, the top is on the left")
end)

T.test("botmap: the run at a ledge closes on it from the floor side and lands its pegs on the top", function()
    local sv = F.server()
    local E, M = sv.env, sv.env.BMX.Bot.Map
    local l = { a = E.Vector(-600, 200, 20), b = E.Vector(600, 200, 20), dir = E.Vector(1, 0, 0),
                side = E.Vector(0, 1, 0), top = 20, ground = 0, len = 1200, key = "k" }
    local g, rideDir = M.LedgeRun(l, 400, E.BMX.Config)
    T.ok(g, "a run")
    T.ok(g.stage.y < 200 - 40, "it starts out on the floor, clear of the kerb")
    T.ok(rideDir.y > 0 and rideDir.x > 0.95, "and closes on it at a shallow angle")
    T.near(g.landAt.y, 200 + M.Config.ledgeLand, 0.01, "landing just onto the top")
    T.near(g.top, 20, 0.01, "a 20 u kerb")
end)

--------------------------------------------------------------------------
-- The show this map can host
--------------------------------------------------------------------------
T.test("botmap: the show is what the map can host -- a funbox's air is poses and whips, not flips", function()
    local sv = F.server()
    local E = sv.env
    local Bot, M = E.BMX.Bot, E.BMX.Bot.Map
    local face = { key = "f1", foot = E.Vector(0, 0, 0), lip = E.Vector(128, 0, 86), dir = E.Vector(1, 0, 0),
                   height = 86, angle = math.rad(32), deck = 240, width = 200 }
    M.cat = { faces = { face }, ledges = {}, map = E.game.GetMap(), why = {} }
    local has = {}
    for _, n in ipairs(Bot.TrickListFor(nil)) do has[n] = true end
    for _, n in ipairs({ "Tailwhip", "Barspin", "Superman", "No-Hander", "Can-Can", "X-Up", "Tabletop", "Turndown",
                         "Bunny Hop", "Wheelie", "Stoppie", "Combo" }) do
        T.ok(has[n], n .. " is in the show")
    end
    for _, n in ipairs({ "Backflip", "Frontflip", "Barrel Roll", "360", "Double Peg Grind", "Crank Grind" }) do
        T.ok(not has[n], n .. " is not: nothing on this map for it")
    end
    M.cat.ledges = { { key = "l1", len = 800 } }
    has = {}
    for _, n in ipairs(Bot.TrickListFor(nil)) do has[n] = true end
    T.ok(has["Double Peg Grind"], "a ledge brings the peg grind in")
    E.GetConVar("bmx_bot_props"):SetString("1")
    has = {}
    for _, n in ipairs(Bot.TrickListFor(nil)) do has[n] = true end
    T.ok(has["Backflip"] and has["Crank Grind"], "with bmx_bot_props 1 it is the whole show again")
end)

T.test("botmap: every trick in the show has a routine, the poses included", function()
    local sv = F.server()
    local Bot = sv.env.BMX.Bot
    for _, n in ipairs(Bot.PoseTricks) do
        T.eq(type(Bot.Tricks[n]), "function", n .. " has a routine")
        T.ok(sv.env.BMX.TrickForPose(Bot.PoseOf[n]), n .. " holds a pose the scoring knows")
    end
end)

T.test("botmap: spots are used in turn, the least used first", function()
    local sv, bike, _, brain = rig()
    local E, M = sv.env, sv.env.BMX.Bot.Map
    local a = { key = "a", at = E.Vector(100, 0, 0) }
    local b = { key = "b", at = E.Vector(2000, 0, 0) }
    local at = function(it) return it.at end
    local score = function() return 0 end
    T.eq(M.Pick(brain, { a, b }, score, at), a, "the nearer first")
    M.Stat("a").used = 1
    T.eq(M.Pick(brain, { a, b }, score, at), b, "then the one not used yet, though it is further")
end)

T.test("botmap: a trick off a face records the air it gave and whether it landed", function()
    local sv, bike, _, brain = rig()
    local E, Bot, M = sv.env, sv.env.BMX.Bot, sv.env.BMX.Bot.Map
    Bot.Tricks["_test_face"] = function(b)
        b.mapFaceKey = "face1"
        b.lastAir = 0.9
        return true
    end
    local r = perform(sv, brain, "_test_face", 5)
    T.ok(r and r.ok, "done")
    local s = M.Stat("face1")
    T.eq(s.landed, 1, "a landing counted")
    T.near(s.air, 0.9, 1e-6, "and its air")
    Bot.Tricks["_test_face"] = nil
end)

T.test("botmap: thrown off into something (a pier's plinth), it is put on open ground, not back on where it lay", function()
    local E0 = F.server().env
    local sv = F.server({ solids = { { E0.Vector(400, -60, -64), E0.Vector(520, 60, 12) } } })
    local E = sv.env
    local bike = F.bike(sv)
    local ply = F.scripted(sv, bike)
    sv:run(0.5)
    local brain = E.BMX.Bot.Attach(ply, bike, { quiet = true, home = E.Vector(0, 0, sv.world.groundZ) })
    -- Lying half inside the plinth, the rider off.
    ply:ExitVehicle()
    F.place(bike, E.Vector(460, 0, sv.world.groundZ + 6), E.Angle(0, 0, 0))
    T.ok(E.BMX.Bot.Embedded(bike, ply), "the bike is embedded")
    brain.nextMount = 0
    brain:recover()
    sv:run(0.5)
    T.ok(not E.BMX.Bot.Embedded(bike, ply), "and is out of it")
    T.ok(bike:GetPos():Distance(E.Vector(460, 0, 0)) > 100, "moved to open ground")
end)

T.test("botmap: a tall kicker's air is a flip's; a funbox's is not", function()
    local sv = F.server()
    local E = sv.env
    local Bot, M = E.BMX.Bot, E.BMX.Bot.Map
    local k = { key = "k1", kicker = true, height = 190 }
    local f = { key = "f1", kicker = false, height = 86 }
    T.ok(M.FaceAir(k) >= Bot.AirNeed("Barrel Roll"), "190 u kicker: " .. M.FaceAir(k) .. " s, a barrel roll's")
    T.ok(M.FaceAir(f) < Bot.AirNeed("Backflip"), "a funbox: " .. M.FaceAir(f) .. " s, not a flip's")
    M.cat = { faces = { k }, ledges = {}, pipes = { { key = "p1", len = 300 } }, map = E.game.GetMap(), why = {} }
    local has = {}
    for _, n in ipairs(Bot.TrickListFor(nil)) do has[n] = true end
    for _, n in ipairs({ "Backflip", "Frontflip", "Barrel Roll", "360", "Crank Grind", "Superman Backflip" }) do
        T.ok(has[n], n .. " is in the show with a kicker and a pipe on the map")
    end
end)

T.test("botmap: a 4 u pipe 18 u up is found as a crank grind's pipe, running its own way", function()
    local E0 = F.server().env
    local sv = F.server({ solids = { { E0.Vector(-2, -300, 0), E0.Vector(2, 300, 18) } } })
    local E, M = sv.env, sv.env.BMX.Bot.Map
    local gz = sv.world.groundZ
    local p = M.PipeAt(E.Vector(-40, 0, gz), E.Vector(1, 0, 0))
    T.ok(p, "a pipe")
    T.near(p.pos.z, 18, 0.5, "its top")
    T.ok(math.abs(p.dir.y) > 0.99, "running along y")
    local pipes = M.PipesFrom({ p }, M.Config)
    T.eq(#pipes, 1, "one pipe")
    T.ok(pipes[1].len >= 500, "walked to its ends: " .. pipes[1].len .. " u")
    local wide = F.server({ solids = { { E0.Vector(-40, -300, 0), E0.Vector(40, 300, 18) } } })
    T.eq(wide.env.BMX.Bot.Map.PipeAt(wide.env.Vector(-80, 0, wide.world.groundZ), wide.env.Vector(1, 0, 0)), nil,
        "an 80 u box is a ledge's business, not a pipe")
end)
