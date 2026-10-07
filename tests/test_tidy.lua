--[[--------------------------------------------------------------------------
    Left alone, it goes (sv_tidy.lua): anything a player spawned is removed
    once nobody has touched it for bmx_idle_cleanup seconds (120).
----------------------------------------------------------------------------]]

local F = require("lib.fixture")

local LIMIT = 120

local function scene()
    local sv, world = F.server()
    local E = sv.env
    local ply = sv:player("Spawner")
    ply:SetPos(E.Vector(-2000, -2000, 0))      -- well away from anything
    return sv, E, E.BMXMode.Tidy, ply
end

local function wait(sv, T, s)
    -- sweep the way the timer does, every T.SWEEP seconds
    local n = math.ceil(s / T.SWEEP)
    for _ = 1, n do
        sv.world.time = sv.world.time + T.SWEEP
        T.Sweep()
    end
end

local function prop(E, ply, pos)
    local e = E.ents.Create("prop_physics")
    e:SetPos(pos or E.Vector(0, 0, 0))
    e:Spawn()
    E.hook.Run("PlayerSpawnedProp", ply, "models/props_junk/wood_crate001a.mdl", e)
    return e
end

T.test("tidy: the default is two minutes, and it is a server setting in the menu", function()
    local sv, E = scene()
    T.eq(E.GetConVar("bmx_idle_cleanup"):GetInt(), LIMIT, "120 s")
    local row = E.BMX.Settings.Get("bmx_idle_cleanup")
    T.ok(row and row.scope == "server", "a server row")
    T.eq(#sv.errors, 0, "nothing threw: " .. table.concat(sv.errors, " | "))
end)

T.test("tidy: a prop nobody touches is gone after two minutes, not before, and its owner is told", function()
    local sv, E, Td, ply = scene()
    local e = prop(E, ply)
    wait(sv, Td, LIMIT - 10)
    T.ok(e:IsValid(), "still there at 110 s")
    wait(sv, Td, 15)
    T.ok(not e:IsValid(), "gone after 120 s")
    T.ok(table.concat(ply._chat or {}, "\n"):find("cleared 1 thing", 1, true), "the owner is told")
end)

T.test("tidy: a bike from bmx_spawn or the rental is tracked; riding it keeps it, leaving it does not", function()
    local sv, E, Td, ply = scene()
    local bike = F.bike(sv, "bmx_base", E.Vector(500, 0, sv.world.groundZ + F.restHeight(sv)))
    E.cleanup.Add(ply, "bmx", bike)
    T.ok(Td.Tracked[bike], "cleanup.Add tracks it")
    ply:EnterVehicle(bike:GetPod())
    wait(sv, Td, LIMIT * 3)
    T.ok(bike:IsValid(), "ridden: kept")
    ply:ExitVehicle()
    ply:SetPos(E.Vector(-2000, -2000, 0))
    wait(sv, Td, LIMIT + 5)
    T.ok(not bike:IsValid(), "left: gone")
end)

T.test("tidy: used, held, toolgunned or moved counts as touched", function()
    local sv, E, Td, ply = scene()
    local used, held, tooled, moved = prop(E, ply), prop(E, ply, E.Vector(300, 0, 0)),
        prop(E, ply, E.Vector(600, 0, 0)), prop(E, ply, E.Vector(900, 0, 0))
    wait(sv, Td, LIMIT - 20)
    E.hook.Run("PlayerUse", ply, used)
    E.hook.Run("OnPhysgunPickup", ply, held)
    E.hook.Run("CanTool", ply, { Entity = tooled }, "weld")
    moved._pos = E.Vector(950, 0, 0)
    wait(sv, Td, 40)
    T.ok(used:IsValid() and tooled:IsValid() and moved:IsValid(), "each got a fresh two minutes")
    wait(sv, Td, LIMIT * 2)
    T.ok(held:IsValid(), "held in the physgun all along: kept")
    T.ok(not used:IsValid() and not tooled:IsValid() and not moved:IsValid(), "the rest went in the end")
    E.hook.Run("PhysgunDrop", ply, held)
    wait(sv, Td, LIMIT + 5)
    T.ok(not held:IsValid(), "dropped and left: gone")
end)

T.test("tidy: a player standing on it keeps it", function()
    local sv, E, Td, ply = scene()
    local e = prop(E, ply, E.Vector(0, 0, 0))
    local other = sv:player("Stander")
    other:SetPos(E.Vector(0, 0, e:OBBMaxs().z))   -- on top of it
    wait(sv, Td, LIMIT * 2)
    T.ok(e:IsValid(), "stood on: kept")
    other:SetPos(E.Vector(3000, 0, 0))
    wait(sv, Td, LIMIT + 5)
    T.ok(not e:IsValid(), "walked off and left: gone")
end)

T.test("tidy: welded things go together, as long as one of them is touched", function()
    local sv, E, Td, ply = scene()
    local a, b = prop(E, ply), prop(E, ply, E.Vector(40, 0, 0))
    E.constraint.GetAllConstrainedEntities = function(ent)
        if ent == a or ent == b then return { [a] = a, [b] = b } end
        return { [ent] = ent }
    end
    for _ = 1, 6 do
        wait(sv, Td, 30)
        E.hook.Run("PlayerUse", ply, a)
    end
    T.ok(a:IsValid() and b:IsValid(), "b kept because a is in use")
    wait(sv, Td, LIMIT + 5)
    T.ok(not a:IsValid() and not b:IsValid(), "both gone once neither is")
end)

T.test("tidy: map entities, rental machines and constraints are never cleared; 0 switches it off", function()
    local sv, E, Td, ply = scene()
    local mapped = E.ents.Create("prop_physics") mapped:Spawn()
    local machine = E.ents.Create("bmx_rental") machine:Spawn()
    local weld = E.ents.Create("phys_constraint") weld:Spawn()
    E.cleanup.Add(ply, "constraints", weld)
    T.ok(not Td.Tracked[weld], "a constraint is not tracked")
    local e = prop(E, ply)
    E.GetConVar("bmx_idle_cleanup"):SetString("0")
    wait(sv, Td, LIMIT * 3)
    T.ok(e:IsValid(), "off: nothing cleared")
    E.GetConVar("bmx_idle_cleanup"):SetString("120")
    wait(sv, Td, LIMIT + 5)
    T.ok(not e:IsValid(), "on again: cleared")
    T.ok(mapped:IsValid() and machine:IsValid() and weld:IsValid(), "the map's own things and the welds stay")
end)
