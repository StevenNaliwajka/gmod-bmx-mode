--[[--------------------------------------------------------------------------
    Personal bests and the leaderboard (sv_scores.lua): bests update and
    persist, the table sorts and caps, a write is batched, and nothing a bot,
    a noclipper or a physgun produced is counted.
----------------------------------------------------------------------------]]

local F = require("lib.fixture")
local gmod = require("lib.gmod")

local PATH = "bmx/scores/gm_flatgrass.json"

local function setup()
    local sv = F.server()
    local E = sv.env
    return sv, E, E.BMX.Scores
end

-- A trick as the scoring hands it to the public hook.
local function land(E, ply, trick, bike)
    E.hook.Run("BMX_TrickLanded", ply, trick, trick.points, bike)
end

local function newBests(sv)
    local n = 0
    for _, m in ipairs(sv.world.wire) do if m.name == "bmx_newbest" then n = n + 1 end end
    return n
end

T.test("scores: a landed trick sets the bests it carries, and tells the rider", function()
    local sv, E, S = setup()
    local bike = F.bike(sv)
    local ply = F.rider(sv, bike)
    land(E, ply, { name = "Backflip", count = 1, points = 500, air = 1.234 }, bike)
    T.eq(S.Personal(ply, "trick", "stock"), 500, "best trick")
    T.eq(S.Personal(ply, "air", "stock"), 1.23, "biggest air, to the hundredth")
    T.eq(S.Personal(ply, "manual", "stock"), nil, "no manual in a flip")
    T.eq(newBests(sv), 2, "a NEW BEST for each of the two")

    land(E, ply, { name = "Wheelie", count = 1, points = 90, held = 3.5 }, bike)
    T.eq(S.Personal(ply, "manual", "stock"), 3.5, "a wheelie is a manual")
    T.eq(S.Personal(ply, "trick", "stock"), 500, "and a smaller trick does not lower the best")

    land(E, ply, { name = "Crank Grind", count = 1, points = 140, grind = 2.25 }, bike)
    T.eq(S.Personal(ply, "grind", "stock"), 2.25, "grind seconds")
end)

T.test("scores: a lower or equal result is not a new best", function()
    local sv, E, S = setup()
    local bike = F.bike(sv)
    local ply = F.rider(sv, bike)
    T.ok(S.Record(ply, "stock", "trick", 400), "first is a best")
    T.ok(not S.Record(ply, "stock", "trick", 400), "equal is not")
    T.ok(not S.Record(ply, "stock", "trick", 399), "lower is not")
    T.ok(S.Record(ply, "stock", "trick", 401), "higher is")
    T.ok(not S.Record(ply, "stock", "trick", 0), "nothing is not a score")
    T.ok(not S.Record(ply, "stock", "trick", 0 / 0), "NaN is not a score")
end)

T.test("scores: a banked combo is the combo best, and a bailed one is nothing", function()
    local sv, E, S = setup()
    local bike = F.bike(sv)
    local ply = F.rider(sv, bike)
    sv:run(0.5)
    -- End to end through the real scoring: two tricks, ride away clean.
    bike:AwardTricks({ { name = "Backflip", count = 1, points = 500 } })
    sv:run(0.3)
    bike:AwardTricks({ { name = "Crank Grind", count = 1, points = 140 } })
    sv:run(1.3)
    T.eq(S.Personal(ply, "combo", "stock"), 1280, "640 + the 640 bonus")

    bike:AwardTricks({ { name = "Backflip", count = 1, points = 500 } })
    bike:AwardTricks({ { name = "Barrel Roll", count = 1, points = 400 } })
    bike:Crash("impact", 0.5)
    T.eq(S.Personal(ply, "combo", "stock"), 1280, "a bailed combo changes nothing")
end)

T.test("scores: the same player on two bikes keeps two bests", function()
    local sv, E, S = setup()
    local ply = sv:player("Two")
    S.Record(ply, "stock", "trick", 300)
    S.Record(ply, "cruiser", "trick", 900)
    T.eq(S.Personal(ply, "trick", "stock"), 300, "stock")
    T.eq(S.Personal(ply, "trick", "cruiser"), 900, "cruiser")
    local all = S.Top("trick")
    T.eq(#all, 1, "every bike: a player once")
    T.eq(all[1].v, 900, "at their best")
end)

T.test("scores: the table sorts best first and keeps ten", function()
    local sv, E, S = setup()
    for i = 1, 12 do
        S.Record(sv:player("P" .. i), "stock", "trick", i * 100)
    end
    local top = S.Top("trick", "stock")
    T.eq(#top, 10, "capped at ten")
    T.eq(top[1].v, 1200, "best first")
    T.eq(top[10].v, 300, "the two lowest fell off")
    for i = 2, #top do T.ok(top[i - 1].v >= top[i].v, "sorted at " .. i) end

    -- A player in the table improving moves them; it does not add a row.
    local p3 = nil
    for _, p in ipairs(sv.players) do if p:Nick() == "P3" then p3 = p end end
    S.Record(p3, "stock", "trick", 5000)
    top = S.Top("trick", "stock")
    T.eq(#top, 10, "still ten")
    T.eq(top[1].name, "P3", "P3 is first")
    local n = 0
    for _, e in ipairs(top) do if e.name == "P3" then n = n + 1 end end
    T.eq(n, 1, "once")
end)

T.test("scores: someone outside the top ten still gets a session best", function()
    local sv, E, S = setup()
    for i = 1, 10 do S.Record(sv:player("P" .. i), "stock", "trick", 1000 + i) end
    local low = sv:player("Low")
    T.ok(S.Record(low, "stock", "trick", 50), "a first result is a best, even off the table")
    T.eq(S.Personal(low, "trick", "stock"), 50, "kept for the session")
    T.ok(not S.Record(low, "stock", "trick", 40), "and compared against")
    T.eq(#S.Top("trick", "stock"), 10, "though the table is untouched")
end)

T.test("scores: saved to data/bmx/scores/<map>.json and loaded again", function()
    local sv, E, S = setup()
    local ply = sv:player("Saver")
    S.Record(ply, "stock", "combo", 2000)
    T.ok(S.Save(), "a dirty table is written")
    T.ok(sv.files[PATH], "at the map's own file: " .. tostring(next(sv.files)))
    T.ok(not S.Save(), "and a clean one is not written again")

    local world = gmod.World()
    local sv2 = gmod.Realm(world, "server")
    sv2.files[PATH] = sv.files[PATH]
    sv2:boot()
    local top = sv2.env.BMX.Scores.Top("combo", "stock")
    T.eq(#top, 1, "one entry came back")
    T.eq(top[1].name, "Saver", "with the name")
    T.eq(top[1].v, 2000, "and the value")
    T.eq(top[1].sid, ply:SteamID64(), "and the account it belongs to")
end)

T.test("scores: a broken file starts empty and says so, rather than breaking the load", function()
    local world = gmod.World()
    local sv = gmod.Realm(world, "server")
    sv.files[PATH] = "{ this is not json"
    sv:boot()
    T.eq(#sv.env.BMX.Scores.Top("combo"), 0, "empty")
    T.ok(#sv.errors > 0, "and reported")
end)

T.test("scores: writes are batched every 30 s and once more on shutdown", function()
    local sv, E, S = setup()
    local ply = sv:player("Batch")
    S.Record(ply, "stock", "trick", 700)
    sv:run(10)
    T.eq(sv.files[PATH], nil, "nothing written inside the window: not on the trick")
    sv:run(21)
    T.ok(sv.files[PATH], "written once the 30 s are up")

    sv.files[PATH] = nil
    S.Record(ply, "stock", "trick", 800)
    E.hook.Run("ShutDown")
    T.ok(sv.files[PATH], "and on the way out, however recent")
    T.ok(sv.files[PATH]:find("800", 1, true), "with the latest")
end)

T.test("scores: a bot, a scripted rider, a noclipper and a physgun do not count", function()
    local sv, E, S = setup()
    local bike = F.bike(sv)

    local bot = sv:player("Bot", { bot = true })
    T.ok(not S.Counts(bot, bike), "a bot")
    local sc = sv:player("Scripted")
    sc.BMXScripted = true
    T.ok(not S.Counts(sc, bike), "a scripted rider")
    T.ok(S.Counts(bot, bike, true), "unless a game invited it")

    local nc = sv:player("Noclip")
    nc._moveType = E.MOVETYPE_NOCLIP
    local ok, why = S.Counts(nc, bike)
    T.ok(not ok and why == "noclip", "noclip")

    local human = sv:player("Human")
    T.ok(S.Counts(human, bike), "a plain rider")
    E.hook.Run("PhysgunPickup", sv:player("Griefer"), bike)
    T.ok(not S.Counts(human, bike), "a bike held in the physgun")
    E.hook.Run("PhysgunDrop", sv:player("Griefer"), bike)
    T.ok(not S.Counts(human, bike), "and for a moment after it lets go")
    sv:run(S.CarryGrace + 0.5)
    T.ok(S.Counts(human, bike), "then it counts again")

    -- Through the hooks, which is what matters.
    land(E, bot, { name = "Backflip", count = 1, points = 999 }, bike)
    land(E, nc, { name = "Backflip", count = 1, points = 999 }, bike)
    T.eq(#S.Top("trick"), 0, "none of it reached the table")
    land(E, human, { name = "Backflip", count = 1, points = 10 }, bike)
    T.eq(#S.Top("trick"), 1, "a plain rider's did")
end)

T.test("scores: a ridden bike's physgun pickup (already refused) does not taint it", function()
    local sv, E, S = setup()
    local bike = F.bike(sv)
    local ply = F.rider(sv, bike)
    T.eq(E.hook.Run("PhysgunPickup", sv:player("Stranger"), bike), false, "refused while ridden")
    T.ok(not bike.BMXCarried, "so the rider is not marked as carried")
    T.ok(S.Counts(ply, bike), "and still counts")
end)

T.test("scores: the client panel, the banner and the sign's data load and read the wire", function()
    local sv, E, S = setup()
    local ply = sv:player("Wire")
    S.Record(ply, "stock", "trick", 1500)
    S.Record(ply, "stock", "air", 2.5)
    land(E, ply, { name = "Backflip", count = 1, points = 1600 })   -- a NEW BEST, with its banner

    local cl = F.client(sv.world)
    cl.localPlayer = ply
    S.Send(ply, "")
    S.Send(ply, "stock")
    for _, m in ipairs(sv.world.wire) do
        if m.name == "bmx_scores" then cl:deliver(m) end
        if m.name == "bmx_newbest" then cl:deliver(m) end
    end
    local c = cl.env.BMX.ScoresCache()
    T.ok(c, "a cache arrived")
    T.eq(c.stats.trick.top[1].name, "Wire", "the name")
    T.eq(c.stats.trick.top[1].v, 1600, "the value")
    T.ok(c.stats.trick.top[1].mine, "marked as yours")
    T.eq(c.stats.air.mine, 2.5, "your own best")
    cl.env.hook.Run("HUDPaint")
    local saw = false
    for _, t in ipairs(cl.texts) do if t == "NEW BEST" then saw = true end end
    T.ok(saw, "the NEW BEST banner is drawn")
    T.eq(cl.env.BMX.Scores.Format("air", 2.5), "2.50 s", "seconds")
    T.eq(cl.env.BMX.Scores.Format("trick", 1234567), "1,234,567 pts", "points, with commas")
end)
