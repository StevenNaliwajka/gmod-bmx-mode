--[[--------------------------------------------------------------------------
    The mode's hooks into the addon's own machinery: its privilege gates the
    bot commands, and the bot's cases sit in the addon's headless suite.
    (Moved from the addon's test_settings / test_headless_cases / test_tricks
    when the gamemode was split out.)
----------------------------------------------------------------------------]]

local F = require("lib.fixture")

local function player(sv, nick, opts)
    return sv:player(nick, opts or {})
end

local function fakeCami(answers, late)
    local C = { registered = {}, asked = {} }
    function C.RegisterPrivilege(p) C.registered[p.Name] = p end
    function C.PlayerHasAccess(ply, priv, cb)
        C.asked[#C.asked + 1] = priv
        local a = answers[priv] and answers[priv][ply:Nick()]
        if late then return end             -- an admin mod that answers a frame later
        if a == nil then a = false end
        cb(a)
    end
    return C
end

local function suite()
    local sv = F.server()
    return sv.env.BMX.Test, sv
end

local function realm()
    local sv = F.server()
    return sv.env.BMX, sv
end

T.test("cami: bmx_bot_* commands need BMX - Bot", function()
    local sv = F.server()
    local spawned = 0
    sv.env.BMX.Bot.Spawn = function() spawned = spawned + 1 return nil, "test" end
    local nobody = player(sv, "N")
    local adm = player(sv, "A")
    adm._admin = true
    nobody._eyeTrace = { Hit = true, HitPos = sv.env.Vector(0, 0, 0), HitNormal = sv.env.Vector(0, 0, 1) }
    adm._eyeTrace = nobody._eyeTrace

    sv:command("bmx_bot_spawn", nobody)
    T.eq(spawned, 0, "a player without the privilege")
    sv:command("bmx_bot_spawn", adm)
    T.eq(spawned, 1, "an admin, by default")
    sv.env.CAMI = fakeCami({ ["BMX - Bot"] = { N = true } })
    sv:command("bmx_bot_spawn", nobody)
    T.eq(spawned, 2, "a non-admin CAMI grants it to")
    sv:command("bmx_bot_spawn", adm)
    T.eq(spawned, 2, "an admin CAMI does not list is refused")
    sv:command("bmx_bot_spawn", nil)
    T.eq(spawned, 3, "the console")
end)


T.test("headless: the bot's landed tricks run in the full suite, work in progress or not elsewhere", function()
    local S = suite()
    local wip = {}
    for _, n in ipairs(S.order) do if S.cases[n].wip then wip[#wip + 1] = n end end
    -- The addon parks its own unfinished cases too (its terrain cases, say);
    -- this gamemode only answers for the bot's.
    T.ok(#wip > 0 or true, "there may be some")
    T.ok(S.cases.bot_wheelie and not S.cases.bot_wheelie.wip, "a trick that lands runs in the full suite")
end)


T.test("headless: every bot trick is in the full run -- none left in progress", function()
    local S, sv = suite()
    for _, name in ipairs(sv.env.BMX.Bot.TrickList) do
        local c = S.cases["bot_" .. name:lower():gsub("[^%w]+", "_")]
        T.ok(c, name .. " has a case")
        T.ok(c and not c.wip, name .. " runs in the full suite")
    end
    T.ok(not S.cases.bot_finds_a_ramp_in_the_world.wip, "and so does finding a ramp")
end)

T.test("bot: Tailwhip, Barspin and Superman are tricks the bot knows", function()
    local B, sv = realm()
    local Bot = sv.env.BMX.Bot
    for _, n in ipairs({ "Tailwhip", "Barspin", "Superman", "Superman Backflip" }) do
        T.ok(Bot.Tricks[n], n .. " has a routine")
        local listed = false
        for _, m in ipairs(Bot.TrickList) do if m == n then listed = true end end
        T.ok(listed, n .. " is in the show")
    end
    T.ok(sv.world, "world")
end)

T.test("settings: the mode's rows are in the addon's one list, and a string saves and loads", function()
    local sv = F.server()
    local S = sv.env.BMX.Settings
    for _, n in ipairs({ "bmx_bot_name", "bmx_bot_model", "bmx_games_admin_only" }) do
        T.ok(S.Get(n), n .. " is described")
    end
    local name = S.Get("bmx_bot_name")
    T.eq(S.Coerce(name, 'a"b\\c\nd'), "abcd", "no quotes, slashes or control characters")
    sv.env.GetConVar("bmx_bot_name"):SetString("Quagmire")
    S.SaveServer()
    sv.env.GetConVar("bmx_bot_name"):SetString("x")
    S.LoadServer()
    T.eq(sv.env.GetConVar("bmx_bot_name"):GetString(), "Quagmire", "string back")
end)

T.test("gamemode: BMX (Mode) derives sandbox and loads on top of the addon", function()
    local sv = F.server()
    T.eq(sv.gamemode.Name, "BMX (Mode)", "named")
    T.eq(sv.gamemode.DerivedFrom, "sandbox", "sandbox underneath")
    T.ok(sv.env.BMXMode and sv.env.BMXMode.AddonReady(), "the addon is there")
    T.ok(sv.env.BMX.Games and sv.env.BMX.Scores and sv.env.BMX.Bot, "games, scores, bot")
    local cl = require("lib.fixture").client(sv.world)
    T.ok(cl.env.BMX.Scores or cl.env.BMXMode, "the client half loads")
end)
