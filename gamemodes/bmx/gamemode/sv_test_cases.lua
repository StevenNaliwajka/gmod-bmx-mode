--[[--------------------------------------------------------------------------
    gamemodes/bmx/gamemode/sv_test_cases.lua

    The bot's cases for the BMX addon's headless suite (the addon's
    lua/bmx/sv_test.lua: bmx_test, or bmx_test bot_* for just these). They
    register with the addon's BMX.Test the same way the addon's own cases do,
    so they run on a real server with the gamemode on.
----------------------------------------------------------------------------]]

local T = BMX.Test
if not T or not T.Case then return end


--------------------------------------------------------------------------
-- THE BOT (sv_bot.lua): every trick in its list, on a real server, judged by
-- the addon's own scoring rather than by what the bot thinks it did.
--
-- The bot is attached to the harness's own scripted rider and bike, so these
-- run exactly like any other case. Each trick finds its own room on the map,
-- its own launch (or puts a kicker down), and rides there itself.
--
-- PROPS ALLOWED HERE. The suite runs on gm_flatgrass, which has nothing to
-- jump or grind: these cases measure the bot's riding, so they let it put its
-- kicker and rail down (bmx_bot_props is 0 on a real server: there it rides
-- the map as it is, sv_botmap.lua; botmap_props_off below checks that).
--------------------------------------------------------------------------
local function botTrick(ctx, name, opts)
    opts = opts or {}
    local brain = BMX.Bot.Attach(ctx.bot, ctx.bike, {
        quiet = true, home = ctx.ground,
        allowSpawnRamp = opts.allowSpawnRamp ~= false, allowFindRamp = opts.allowFindRamp,
    })
    -- WITHIN TWO ATTEMPTS, as the bot's own show allows (it retries a miss).
    -- A real park and real physics vary run to run by a few units -- a grind's
    -- landing, a run-in's speed -- and one attempt measured that variance more
    -- than the bot. Both attempts are logged; two misses still fail the case.
    local result
    for attempt = 1, opts.attempts or 2 do
        result = nil
        BMX.Bot.Perform(brain, name, function(ok, why) result = { ok = ok, why = why } end)
        ctx:waitUntil(function() return result ~= nil end, opts.timeout or 70, name .. " finished")
        ctx:log(string.format("attempt %d: %s", attempt, result and (result.ok and "landed" or ("missed: " .. tostring(result.why))) or "no result"))
        if result and result.ok then break end
        -- Back on the bike before trying again.
        ctx:waitUntil(function() return IsValid(ctx.bike) and ctx.bike:GetDriver() == ctx.bot end, 12, "back on the bike")
    end
    for _, line in ipairs(brain.log) do ctx:log(line) end
    BMX.Bot.Detach(brain)
    ctx:input({})
    return result, brain
end

-- The tricks the bot does not land on a real server yet: run by name while
-- they are worked on, out of the full run until they pass. EMPTY THIS.
local BOT_WIP = {}
BMX.Bot.WIP = BOT_WIP

-- A grind is a hop onto a 2.8 u pipe from a bike that weaves a few units:
-- the bot rides by rather than force a hop it will miss, and tries again, so
-- a grind gets the third attempt the show would give it too.
local ATTEMPTS = { ["Crank Grind"] = 3, ["Double Peg Grind"] = 3 }

for _, name in ipairs(BMX.Bot.TrickList) do
    local tries = ATTEMPTS[name] or 2
    T.Case("bot_" .. name:lower():gsub("[^%w]+", "_"), { timeout = 85 * tries, wip = BOT_WIP[name],
        desc = "the bot lands a " .. name .. " within " .. tries .. " attempts, by the scoring's own account" },
    function(ctx)
        local r = botTrick(ctx, name, { attempts = tries })
        ctx:ok(r and r.ok, name .. " landed: " .. tostring(r and r.why or "no result"))
        ctx:ok(IsValid(ctx.bike:GetDriver()), "and the rider is still on the bike")
    end)
end

--------------------------------------------------------------------------
-- FRAME AND BAR SPINS, AND POSES (G03, G17): the bot commands them off the
-- ramp the way the flips are, and the addon's own scoring is the judge. A
-- whip that came down out of line, or a pose held into the landing, bails
-- (the bike would not be rideable / the rider has no hands), so a landed
-- trick with the rider still aboard is the whole claim.
--------------------------------------------------------------------------
T.Case("tailwhip_lands", { timeout = 170,
    desc = "off the ramp case, a tailwhip is commanded: it completes, scores, and the bike lands rideable" },
function(ctx)
    local r, brain = botTrick(ctx, "Tailwhip")
    ctx:ok(r and r.ok, "tailwhip landed: " .. tostring(r and r.why or "no result"))
    ctx:ok(IsValid(ctx.bike:GetDriver()), "and the rider is still on the bike")
    local whip = brain.scored and brain:scoredSince(0, "Tailwhip")
    ctx:ok(whip and whip.points >= 600, "paid at least one turn's 600: " .. tostring(whip and whip.points))
    local a, b = BMX.PartsOffLine(ctx.bike.st)
    ctx:ok(a < 0.01 and b < 0.01, "and the frame is back in line (" .. tostring(a) .. ")")
end)

T.Case("superman_backflip_lands", { timeout = 170,
    desc = "off the ramp case, a backflip with a superman held through it: one compound trick, landed" },
function(ctx)
    local r, brain = botTrick(ctx, "Superman Backflip")
    ctx:ok(r and r.ok, "Backflip Superman landed: " .. tostring(r and r.why or "no result"))
    ctx:ok(IsValid(ctx.bike:GetDriver()), "and the rider is still on the bike")
    local c = brain:scoredSince(0, "Backflip Superman")
    ctx:ok(c and c.points > 500, "paid as both, with a compound bonus: " .. tostring(c and c.points))
end)

T.Case("bot_finds_a_ramp_in_the_world", { timeout = 170,
    desc = "with no kicker of its own allowed, the bot finds a ramp it was not told about and flips off it" },
function(ctx)
    -- A plain tilted plate, put down the way a map's ramp or a player's prop
    -- would be -- not through BMX.SpawnKicker, so nothing about it is known to
    -- the bot except what its traces find.
    local yaw, best = 0, 0
    for k = 0, 7 do
        local len = BMX.Launch.Runway(ctx.ground, BMX.Launch.DirOf(k * 45), 1800, { filter = { ctx.bike, ctx.bot } })
        if len > best then yaw, best = k * 45, len end
    end
    if best < 1700 then
        ctx:log(string.format("no 1700 u straight on %s to put a test ramp on (best %.0f): " ..
            "this case is for open ground, and is not run here", game.GetMap(), best))
        return
    end
    local dir = BMX.Launch.DirOf(yaw)
    -- A long, gentle ramp, the kind a park has: two big plates end to end at
    -- 14 degrees. (A short steep plate was tried first, and correctly turned
    -- down: it cannot give the air a flip needs.)
    local plates = {}
    local L = 379.6
    for i = 0, 1 do
        local plate = ents.Create("prop_physics")
        plate:SetModel("models/hunter/plates/plate8x8.mdl")
        local f = ctx.ground + dir * (650 + i * L * math.cos(math.rad(14))) + Vector(0, 0, i * L * math.sin(math.rad(14)))
        local centre, ang = BMX.Launch.KickerGeometry(f, yaw, L, 3.4, math.rad(14))
        plate:SetPos(centre)
        plate:SetAngles(ang)
        plate:Spawn()
        local pp = plate:GetPhysicsObject()
        if IsValid(pp) then pp:SetPos(centre) pp:SetAngles(ang) pp:EnableMotion(false) end
        plates[#plates + 1] = plate
    end
    local plate = plates[1]
    ctx:wait(0.2)
    ctx:log(string.format("plate put %.0f deg off, %.0f u of runway that way", yaw, best))

    local r, brain = botTrick(ctx, "Backflip", { allowSpawnRamp = false })
    local found = false
    for _, line in ipairs(brain.log) do if line:find("found a launch", 1, true) then found = true end end
    ctx:ok(found, "it found the plate with its own traces")
    ctx:ok(r and r.ok, "and backflipped off it: " .. tostring(r and r.why))
    for _, p in ipairs(plates) do SafeRemoveEntity(p) end
end)

T.Case("bot_spawns_named_and_dressed", { rider = false, timeout = 40,
    desc = "bmx_bot_spawn's bot has its name and model, sits on its bike, and rides" },
function(ctx)
    local oldName, oldModel = GetConVar("bmx_bot_name"):GetString(), GetConVar("bmx_bot_model"):GetString()
    RunConsoleCommand("bmx_bot_name", "BMX Show Bot")
    RunConsoleCommand("bmx_bot_model", "models/player/kleiner.mdl")
    ctx:wait(0.2)
    local b, err = BMX.Bot.Spawn(ctx.ground + Vector(0, 300, 0), 0)
    if not ctx:ok(b ~= nil, "spawned: " .. tostring(err)) then return end
    b.show = false
    ctx:wait(0.5)
    ctx:ok(b.ply:Nick() == "BMX Show Bot", "named by bmx_bot_name: " .. b.ply:Nick())
    ctx:ok(b.ply:GetModel() == "models/player/kleiner.mdl", "dressed by bmx_bot_model: " .. b.ply:GetModel())
    ctx:ok(b.bike:GetDriver() == b.ply, "sitting on its own bike")
    local result
    BMX.Bot.Perform(b, "Bunny Hop", function(ok, why) result = { ok = ok, why = why } end)
    ctx:waitUntil(function() return result ~= nil end, 25, "the hop finished")
    ctx:ok(result and result.ok, "and it rides: a bunny hop, " .. tostring(result and result.why))
    local bike, ply = b.bike, b.ply
    BMX.Bot.Detach(b)
    SafeRemoveEntity(bike)
    if IsValid(ply) then ply:Kick("test over") end
    RunConsoleCommand("bmx_bot_name", oldName)
    RunConsoleCommand("bmx_bot_model", oldModel)
end)

--------------------------------------------------------------------------
-- A GAME OF SKATE (sv_games.lua, bmx/games/skate.lua) between two bots: the
-- whole path on a real server -- bots invited to a lobby, the setter sent off
-- to land something, the scoring's own BMX_TrickLanded setting the trick, the
-- other bot sent after the same one, a letter for a miss -- to a result with
-- no Lua errors. It does not assert WHO wins, only that the game gets there:
-- two bots on a real map are not a deterministic match.
--
-- One letter ("S") so the first miss ends it, and generous clocks because a
-- bot has to ride to a ramp first (the bot_* cases above allow 90 s for one).
--------------------------------------------------------------------------
T.Case("skate_game_with_bots", { rider = false, timeout = 300,
    desc = "two bots play SKATE to a result: a trick set, followed, and a letter or a win" },
function(ctx)
    local G = BMX.Games
    if not ctx:ok(G and G.defs.skate, "the SKATE game is registered") then return end
    local a = BMX.Bot.Spawn(ctx.ground + Vector(0, 400, 0), 0)
    local b = BMX.Bot.Spawn(ctx.ground + Vector(0, -400, 0), 0)
    if not ctx:ok(a and b, "two bots spawned") then return end
    for _, bot in ipairs({ a, b }) do
        bot.show = false                     -- they play, they do not put on their show
        bot.ply.BMXGameBot = true
    end
    ctx:wait(0.5)

    local ended, letters = nil, 0
    hook.Add("BMX_GameEnded", "BMX.Test.Skate", function(_, r) ended = r end)
    hook.Add("BMX_GameLetter", "BMX.Test.Skate", function() letters = letters + 1 end)

    local game = G.Start("skate", nil, { letters = "S", setTime = 60, tryTime = 60 })
    if not ctx:ok(game, "a lobby opened") then return end
    game.guests = { a.ply, b.ply }
    ctx:ok(game:Join(a.ply) and game:Join(b.ply), "both joined")
    ctx:ok(game:Begin(), "and it began")

    ctx:waitUntil(function() return ended ~= nil end, 280, "the game reached a result")
    ctx:log(string.format("SKATE result: winner %s, %d letter(s), state %s",
        ended and IsValid(ended.winner) and ended.winner:Nick() or "none", letters, game.state))
    ctx:ok(game.state == "done", "state is done")
    ctx:ok(ended and #ended.ranking == 2, "both are ranked")

    hook.Remove("BMX_GameEnded", "BMX.Test.Skate")
    hook.Remove("BMX_GameLetter", "BMX.Test.Skate")
    local bikes = { a.bike, b.bike }
    G.Retire(game)                           -- kicks the bots and takes their bikes
    for _, bike in ipairs(bikes) do SafeRemoveEntity(bike) end
end)

--------------------------------------------------------------------------
-- THE MAP AS IT IS (sv_botmap.lua): with props off -- the default -- the bot
-- puts nothing down. On a flat map that is a miss for an air trick, and the
-- world is left as it was.
--------------------------------------------------------------------------
T.Case("botmap_props_off", { timeout = 120,
    desc = "with props off the bot puts no kicker or rail down: on a map with nothing to jump, the tailwhip is a miss and no prop appears" },
function(ctx)
    local before = #ents.FindByClass("prop_physics")
    local r, brain = botTrick(ctx, "Tailwhip", { allowSpawnRamp = false, attempts = 1 })
    ctx:ok(brain and not brain.allowSpawnRamp, "the brain was not allowed props")
    ctx:ok(#ents.FindByClass("prop_physics") == before, "no prop put down (" .. before .. " before, " ..
        #ents.FindByClass("prop_physics") .. " after)")
    if BMX.Bot.Map and BMX.Bot.Map.cat and #BMX.Bot.Map.cat.faces == 0 then
        ctx:ok(r and not r.ok, "nothing on this map for it: a miss (" .. tostring(r and r.why) .. ")")
    end
end)
