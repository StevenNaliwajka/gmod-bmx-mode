--[[--------------------------------------------------------------------------
    Auto ride (sv_autoride.lua): the addon's O key hands a player's bike to
    the trick bot's brain -- the same brain, routes and show Peter rides with
    -- and any ride key hands it back.
----------------------------------------------------------------------------]]

local F = require("lib.fixture")
local gmod = require("lib.gmod")
local IN = gmod.IN

local function cmd(buttons)
    local c = { buttons = buttons or 0 }
    function c:GetButtons() return self.buttons end
    function c:SetButtons(b) self.buttons = b end
    function c:GetForwardMove() return 0 end
    function c:GetSideMove() return 0 end
    function c:SetForwardMove() end
    function c:SetSideMove() end
    function c:SetUpMove() end
    return c
end

local function rig(class)
    local sv = F.server()
    local bike = F.bike(sv, class)
    local ply = F.rider(sv, bike, { name = "Rider" })
    sv:run(0.5)
    return sv, sv.env, bike, ply
end

local function on(E, ply)
    E.hook.Run("PlayerButtonDown", ply, E.KEY_O)
    return E.BMX.AutoRide.Active(ply)
end

T.test("autoride: O puts the trick bot's brain on the player's own bike, quietly, doing the show", function()
    local sv, E, bike, ply = rig()
    T.ok(on(E, ply), "on")
    local b = E.BMX.Bot.brains[ply]
    T.ok(b, "a bot brain")
    T.ok(b == ply.BMXBotBrain and b.bike == bike, "on this player and their bike")
    T.ok(b.autoRide and b.show, "the show, as Peter rides it")
    T.ok(b.quiet, "no chat line for every trick")
    T.ok(not ply:IsBot(), "the player is still the player")
    T.ok(ply.BMXScripted, "the brain writes the input")
    T.eq(#sv.errors, 0, "nothing threw: " .. table.concat(sv.errors, " | "))
end)

T.test("autoride: it rides -- the brain sets off on a trick and drives the bike", function()
    local sv, E, bike, ply = rig()
    on(E, ply)
    local b = E.BMX.Bot.brains[ply]
    local moved, tried = false, false
    sv:run(20, function()
        if (bike.input.throttle or 0) > 0 then moved = true end
        for _, r in pairs(b.results) do if r.tries > 0 then tried = true end end
        return moved and tried
    end)
    T.ok(tried, "a trick from the show was begun: " .. table.concat(b.log, " / "))
    T.ok(moved, "and it pedalled")
    T.eq(#sv.errors, 0, "nothing threw: " .. table.concat(sv.errors, " | "))
end)

T.test("autoride: a ride key takes the bars back; the brain goes, the bike and rider stay", function()
    local sv, E, bike, ply = rig()
    on(E, ply)
    sv:run(2)
    E.hook.Run("StartCommand", ply, cmd(0))
    E.hook.Run("StartCommand", ply, cmd(IN.FORWARD))
    T.ok(not E.BMX.AutoRide.Active(ply), "off")
    T.eq(E.BMX.Bot.brains[ply], nil, "the brain detached")
    T.ok(not ply.BMXScripted, "the keys are the player's")
    T.ok(E.IsValid(bike) and bike:GetDriver() == ply, "still on their bike")
    T.eq(bike.input.throttle, 1, "and W pedals on that keypress")
end)

T.test("autoride: O again, and it is off", function()
    local sv, E, _, ply = rig()
    on(E, ply)
    sv.world.time = sv.world.time + 1
    E.hook.Run("PlayerButtonDown", ply, E.KEY_O)
    T.ok(not E.BMX.AutoRide.Active(ply), "off")
    T.eq(E.BMX.Bot.brains[ply], nil, "brain gone")
end)

T.test("autoride: bmx_bot_remove ends it, but never kicks the player or takes their bike", function()
    local sv, E, bike, ply = rig()
    on(E, ply)
    local a = sv:player("Admin")
    a._admin = true
    sv:command("bmx_bot_remove", a)
    T.ok(not E.BMX.AutoRide.Active(ply), "the HUD and keys agree it is off")
    T.ok(not ply.BMXScripted, "keys back")
    T.ok(E.IsValid(ply) and E.IsValid(bike), "player and bike still here")
end)

T.test("autoride: its bike removed, it is over", function()
    local sv, E, bike, ply = rig()
    on(E, ply)
    bike:Remove()
    sv:run(1)
    T.ok(not E.BMX.AutoRide.Active(ply), "off")
    T.eq(E.BMX.Bot.brains[ply], nil, "brain gone")
end)

T.test("autoride: what it lands never counts towards the player's scores", function()
    local _, E, bike, ply = rig()
    on(E, ply)
    local ok, why = E.BMX.Scores.Counts(ply, bike)
    T.ok(not ok, "not counted")
    T.eq(why, "scripted", "a scripted rider")
end)

T.test("autoride: only what the bot can ride -- not a unicycle", function()
    local _, E, _, ply = rig("bmx_unicycle")
    T.ok(not on(E, ply), "refused")
    local said = ply._chat and ply._chat[#ply._chat] or ""
    T.ok(said:find("cannot ride this one", 1, true), "and says why: " .. said)
    T.ok(not ply.BMXScripted, "keys untouched")
end)

T.test("autoride: not in the middle of a game the player is in", function()
    local _, E, _, ply = rig()
    E.BMX.Games.Active = function() return { state = "play", players = { ply } } end
    T.ok(not on(E, ply), "refused")
    local said = ply._chat and ply._chat[#ply._chat] or ""
    T.ok(said:find("game", 1, true), "and says why: " .. said)
end)
