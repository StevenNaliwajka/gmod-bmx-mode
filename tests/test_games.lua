--[[--------------------------------------------------------------------------
    The games (sv_games.lua, bmx/games/*): lobby and commands, the SKATE
    letter logic turn by turn, Trick Attack and Combo Mambo on their clocks,
    the exclusions, and the HUD wire.
----------------------------------------------------------------------------]]

local F = require("lib.fixture")

local function setup(n)
    local sv = F.server()
    local E = sv.env
    local players = {}
    for i = 1, n or 3 do players[i] = sv:player("P" .. i) end
    return sv, E, E.BMX.Games, players
end

local function land(E, ply, name, points, count)
    E.hook.Run("BMX_TrickLanded", ply, { name = name, count = count or 1, points = points or 100 }, points or 100)
end

local function bail(E, ply)
    E.hook.Run("BMX_Crash", {}, ply, "impact", 0.5)
end

-- A SKATE lobby with everyone in and started.
local function skate(n, opts)
    local sv, E, G, p = setup(n)
    local g = G.Start("skate", p[1], opts)
    for i = 2, #p do g:Join(p[i]) end
    local ok, why = g:Begin()
    T.ok(ok, "began: " .. tostring(why))
    return sv, E, G, g, p
end

T.test("games: three games are registered, with their limits", function()
    local _, _, G = setup(0)
    T.eq(G.defs.skate.min, 2, "SKATE needs two")
    T.eq(G.defs.skate.max, 8, "and takes eight")
    T.ok(G.defs.attack and G.defs.mambo, "attack and mambo")
end)

T.test("games: start, join, leave and status through the commands", function()
    local sv, E, G, p = setup(3)
    sv:command("bmx_game_start", p[1], "skate")
    T.ok(G.Active() and G.Active().state == "lobby", "a lobby is open")
    T.ok(G.Active():Has(p[1]), "the host is in it")
    sv:command("bmx_game_join", p[2])
    T.ok(G.Active():Has(p[2]), "joined")
    sv:command("bmx_game_join", p[2])
    T.ok(p[2]._chat[#p[2]._chat]:find("already"), "twice is refused, and says why")

    sv:command("bmx_game_start", p[3], "attack")
    T.ok(p[3]._chat[#p[3]._chat]:find("already on"), "one game at a time")

    sv:command("bmx_game_start", p[1])         -- the host again: begin
    T.eq(G.Active().state, "running", "the host begins it early")
    sv:command("bmx_game_join", p[3])
    T.ok(not G.Active():Has(p[3]), "SKATE does not take latecomers")

    sv:command("bmx_game_leave", p[2])
    T.eq(G.Active().state, "done", "two players, one leaves: it is over")
    T.ok(G.Active().result.winner == p[1], "the one left wins")
    sv:command("bmx_game_status", p[1])
end)

T.test("games: a lobby with too few players is cancelled when its timer runs out", function()
    local sv, E, G, p = setup(1)
    G.Start("skate", p[1])
    sv:run(G.LobbyTime + 1)
    T.eq(G.Active(), nil, "gone")
end)

T.test("games: only admins start one when bmx_games_admin_only is set", function()
    local sv, E, G, p = setup(2)
    E.GetConVar("bmx_games_admin_only"):SetString("1")
    sv:command("bmx_game_start", p[1], "attack")
    T.eq(G.Active(), nil, "refused")
    p[2]._superadmin = true
    sv:command("bmx_game_start", p[2], "attack")
    T.ok(G.Active(), "an admin can")
end)

T.test("skate: the setter lands a trick and the followers must match it", function()
    local sv, E, G, g, p = skate(3)
    T.eq(g.phase, "set", "starts with a set")
    T.ok(g.setter == p[1], "by the first player")

    land(E, p[2], "Backflip")
    T.eq(g.phase, "set", "nobody else can set")

    land(E, p[1], "Air Time", 130)
    T.eq(g.phase, "set", "Air Time cannot be the call")
    land(E, p[1], "Backflip", 500)
    T.eq(g.phase, "follow", "set")
    T.eq(g.target.id, "backflip", "the trick id is the lower-cased name")
    T.ok(g.current == p[2], "the next player is up")

    land(E, p[3], "Backflip")
    T.ok(g.current == p[2], "out of turn does not count")
    land(E, p[2], "Frontflip")
    T.ok(g.current == p[2], "a different trick does not fail the attempt, it just does not match")
    land(E, p[2], "Backflip")
    T.ok(g.current == p[3], "matched: the next follower")
    land(E, p[3], "Backflip")
    T.eq(g.phase, "set", "round over")
    T.ok(g.setter == p[2], "the next player sets")
    T.eq(g.owed[p[2]] or 0, 0, "nobody got a letter")
    T.eq(g.owed[p[3]] or 0, 0, "nobody got a letter")
end)

T.test("skate: a bail is a letter, and the same count is required", function()
    local sv, E, G, g, p = skate(3)
    land(E, p[1], "Backflip", 1000, 2)
    T.eq(g.target.count, 2, "a double backflip is the call")
    land(E, p[2], "Backflip", 500, 1)
    T.ok(g.current == p[2], "one is not two")
    bail(E, p[2])
    T.eq(g.owed[p[2]], 1, "a bail is a letter")
    T.eq(g:Word(p[2]), "S", "the first letter")
    T.ok(g.current == p[3], "and it is the next one's go")
    bail(E, p[1])
    T.eq(g.owed[p[1]] or 0, 0, "the setter bailing in someone else's turn is nothing")
end)

T.test("skate: the setter who bails or times out sets nothing and takes no letter", function()
    local sv, E, G, g, p = skate(3)
    bail(E, p[1])
    T.ok(g.setter == p[2], "it passes on")
    T.eq(g.owed[p[1]] or 0, 0, "no letter")
    sv:run(g.setTime + 1)
    T.ok(g.setter == p[3], "a timeout passes it on too")
    T.eq(g.owed[p[2]] or 0, 0, "no letter for that either")
end)

T.test("skate: running out of time on a follow is a letter", function()
    local sv, E, G, g, p = skate(2)
    land(E, p[1], "360", 250)
    T.ok(g.current == p[2], "p2 is up")
    sv:run(g.tryTime + 1)
    T.eq(g.owed[p[2]], 1, "the clock gave them a letter")
    T.ok(g.setter == p[2], "and it is their turn to set")
end)

T.test("skate: spelling the word puts you out, and the last one standing wins", function()
    local sv, E, G, g, p = skate(3, { letters = "SK" })
    local ended, letters = nil, 0
    E.hook.Add("BMX_GameEnded", "t", function(game, result) ended = result end)
    E.hook.Add("BMX_GameLetter", "t", function() letters = letters + 1 end)

    land(E, p[1], "Backflip")          -- round 1: p1 sets
    bail(E, p[2])                      --   p2: S
    bail(E, p[3])                      --   p3: S
    T.ok(g.setter == p[2], "p2 sets next")
    land(E, p[2], "Barrel Roll")       -- round 2
    bail(E, p[3])                      --   p3: SK, out
    T.eq(g:Word(p[3]), "SK", "spelled it")
    T.eq(#g:Alive(), 2, "two left")
    T.ok(not ended, "still going")
    bail(E, p[1])                      --   p1: S
    T.ok(g.setter == p[1], "the dead are skipped: p1 sets")
    land(E, p[1], "360")               -- round 3: only p2 follows
    T.ok(g.current == p[2], "p2 is up")
    bail(E, p[2])                      --   p2: SK, out
    T.ok(ended, "the game ended")
    T.ok(ended.winner == p[1], "p1 is the last one standing")
    T.eq(letters, 5, "BMX_GameLetter fired for each letter")
    T.eq(g.state, "done", "state")
    T.eq(#ended.ranking, 3, "everyone ranked")
end)

T.test("skate: a player leaving mid-round does not stall it", function()
    local sv, E, G, g, p = skate(3)
    land(E, p[1], "Backflip")
    T.ok(g.current == p[2], "p2 is up")
    g:Leave(p[2])
    T.ok(g.current == p[3], "p3 is up instead")
    g:Leave(p[1])                      -- the setter leaves: the game has one player left
    T.eq(g.state, "done", "ended")
    T.ok(g.result.winner == p[3], "p3 wins")
end)

T.test("skate: noclip and bots do not play, unless the game invited the bot", function()
    local sv, E, G, g, p = skate(2)
    p[1]._moveType = E.MOVETYPE_NOCLIP
    land(E, p[1], "Backflip")
    T.eq(g.phase, "set", "a noclipper cannot set")
    p[1]._moveType = nil
    land(E, p[1], "Backflip")
    T.eq(g.phase, "follow", "but can once they are not")

    local sv2, E2, G2, p2 = setup(1)
    local bot = sv2:player("Peter Griffin", { bot = true })
    local g2 = G2.Start("skate", p2[1])
    g2:Join(bot)
    g2:Begin()
    land(E2, p2[1], "Backflip")
    T.ok(g2.current == bot, "the bot is up")
    land(E2, bot, "Backflip")
    T.eq(g2.phase, "follow", "an uninvited bot's landing does not count")
    bot.BMXGameBot = true
    land(E2, bot, "Backflip")
    T.eq(g2.phase, "set", "an invited one does")
end)

T.test("skate: an invited bot is told to do the call, and to set when it sets", function()
    local sv, E, G, p = setup(1)
    local bot = sv:player("Peter Griffin", { bot = true })
    bot.BMXGameBot = true
    local asked = {}
    E.BMX.Bot.brains[bot] = { ply = bot, props = {} }   -- no bike: Think will detach it, which is fine
    E.BMX.Bot.Perform = function(b, name) asked[#asked + 1] = name return true end
    E.BMX.Bot.Tricks = E.BMX.Bot.Tricks or {}
    for _, n in ipairs(E.BMX.Bot.TrickList) do E.BMX.Bot.Tricks[n] = E.BMX.Bot.Tricks[n] or function() end end

    local g = G.Start("skate", p[1])
    g.guests = { bot }
    g:Join(bot)
    g:Begin()
    land(E, p[1], "Backflip")
    T.ok(g.current == bot, "the bot is up")
    T.eq(asked[#asked], "Backflip", "and was sent to do a Backflip")

    land(E, bot, "Backflip")
    T.ok(g.setter == bot, "its turn to set")
    T.eq(#asked, 2, "and it was sent off")
    local known = false
    for _, n in ipairs(E.BMX.Bot.TrickList) do if n == asked[2] then known = true end end
    T.ok(known, "to a trick it knows: " .. tostring(asked[2]))

    -- The game sends the bot home when it is over.
    g:Leave(p[1])
    sv:run(G.DoneTime + 1)
    T.eq(G.Active(), nil, "slot free")
    T.ok(not bot.BMXGameBot, "bot released")
    T.ok(bot._kicked, "and sent home")
end)

T.test("attack: everyone scores for two minutes, combos pay their bonus, biggest wins", function()
    local sv, E, G, p = setup(2)
    local ended
    E.hook.Add("BMX_GameEnded", "t", function(_, r) ended = r end)
    local g = G.Start("attack", p[1])
    g:Join(p[2])
    g:Begin()
    land(E, p[1], "Backflip", 500)
    E.hook.Run("BMX_ComboBanked", p[1], { n = 2, base = 640, bonus = 640, total = 1280 }, 1280)
    land(E, p[2], "Backflip", 900)
    T.eq(g.totals[p[1]], 1140, "500 + the 640 bonus, not the chain's own points twice")
    T.eq(g.totals[p[2]], 900, "p2")
    sv:run(60)
    T.ok(not ended, "not over at one minute")
    local late = sv:player("Late")
    T.ok(g:Join(late), "Trick Attack takes latecomers")
    sv:run(61)
    T.ok(ended, "over at two minutes")
    T.ok(ended.winner == p[1], "p1 wins")
    T.eq(#ended.ranking, 3, "everyone is ranked")
    T.eq(ended.ranking[1].v, 1140, "best first")
    sv:run(G.DoneTime + 1)
    T.eq(G.Active(), nil, "then the slot is free")
end)

T.test("attack: a tie is a draw, and nobody scoring is not a win", function()
    local sv, E, G, p = setup(2)
    local g = G.Start("attack", p[1])
    g:Join(p[2])
    g:Begin()
    sv:run(121)
    T.eq(g.result.winner, nil, "no score, no winner")
    local g2
    sv:run(G.DoneTime + 1)
    g2 = G.Start("attack", p[1])
    g2:Join(p[2])
    g2:Begin()
    land(E, p[1], "Backflip", 300)
    land(E, p[2], "Backflip", 300)
    sv:run(121)
    T.eq(g2.result.winner, nil, "a tie is a draw")
end)

T.test("mambo: only the single biggest banked combo counts", function()
    local sv, E, G, p = setup(2)
    local g = G.Start("mambo", p[1])
    g:Join(p[2])
    g:Begin()
    for _ = 1, 30 do land(E, p[1], "Hop", 10) end                 -- thirty small tricks
    E.hook.Run("BMX_ComboBanked", p[1], { n = 2, base = 100, bonus = 100, total = 200 }, 200)
    E.hook.Run("BMX_ComboBanked", p[2], { n = 3, base = 300, bonus = 600, total = 900 }, 900)
    E.hook.Run("BMX_ComboBanked", p[2], { n = 2, base = 50, bonus = 50, total = 100 }, 100)
    T.eq(g.totals[p[1]], 200, "p1: tricks do not count")
    T.eq(g.totals[p[2]], 900, "p2: the best, not the sum")
    sv:run(61)
    T.ok(g.result.winner == p[2], "p2 wins")
end)

T.test("games: a bot, a noclipper or a physgunned bike scores nothing in a timed game", function()
    local sv, E, G, p = setup(2)
    local g = G.Start("attack", p[1])
    g:Join(p[2])
    g:Begin()
    local bot = sv:player("Bot", { bot = true })
    g:Join(bot)
    land(E, bot, "Backflip", 500)
    p[1]._moveType = E.MOVETYPE_NOCLIP
    land(E, p[1], "Backflip", 500)
    p[1]._moveType = nil
    T.eq(g.totals[bot], 0, "the bot")
    T.eq(g.totals[p[1]], 0, "the noclipper")
    local bike = F.bike(sv)
    E.hook.Run("PhysgunPickup", sv:player("G"), bike)
    p[2].BMXBike = bike
    E.hook.Run("BMX_TrickLanded", p[2], { name = "Backflip", count = 1, points = 500 }, 500, bike)
    T.eq(g.totals[p[2]], 0, "a carried bike")
end)

T.test("games: the HUD gets a snapshot, and an empty one when it is over", function()
    local sv, E, G, p = setup(2)
    local g = G.Start("skate", p[1])
    g:Join(p[2])
    g:Begin()
    sv:run(1.2)
    local snaps = {}
    for _, m in ipairs(sv.world.wire) do
        if m.name == "bmx_game" then snaps[#snaps + 1] = m end
    end
    T.ok(#snaps >= 2, "sent to the players")
    local cl = F.client(sv.world)
    cl.localPlayer = p[1]
    for _, m in ipairs(snaps) do cl:deliver(m) end
    local s = cl.env.BMX.GameHUD.Get()
    T.eq(s.name, "SKATE", "title")
    T.eq(s.state, "running", "state")
    T.eq(#s.rows, 2, "a row each")
    cl.env.hook.Run("HUDPaint")
    local saw = false
    for _, t in ipairs(cl.texts) do if t == "P1" then saw = true end end
    T.ok(saw, "drawn")

    g:Leave(p[2])
    sv:run(G.DoneTime + 1)
    snaps = {}
    for _, m in ipairs(sv.world.wire) do if m.name == "bmx_game" then snaps[#snaps + 1] = m end end
    cl:deliver(snaps[#snaps])
    T.eq(cl.env.BMX.GameHUD.Get(), nil, "cleared at the end")
end)
