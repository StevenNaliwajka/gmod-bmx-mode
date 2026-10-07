--[[--------------------------------------------------------------------------
    entities/bmx_leaderboard/shared.lua

    A SIGN that shows the map's top ten, drawn with 3D2D, for an admin to put
    up in the park. It shows one stat at a time and cycles through all five
    every few seconds, unless a stat is chosen. "Bike" empty = every bike.

    The scores themselves live in sv_scores.lua. The sign is only a screen: it
    asks for the table (BMX.Scores.Request) a few times a minute while a player
    is near enough to read it, and draws whatever came back last. Nothing on
    the sign is authoritative and nothing on it can be edited.

    Admin-only to spawn (Q menu > BMX > BMX Leaderboard), because a sign is a
    prop that is on the map for everyone.
----------------------------------------------------------------------------]]

ENT.Type      = "anim"
ENT.Base      = "base_anim"
ENT.PrintName = "BMX Leaderboard"
ENT.Author    = "naliwajka"
ENT.Category  = "BMX"
ENT.Spawnable = true
ENT.AdminOnly = true
ENT.RenderGroup = RENDERGROUP_BOTH

-- A big flat plate, stood on its edge by SpawnFunction. The model is only the
-- board; every pixel of the sign is drawn over it.
ENT.Model = "models/hunter/plates/plate2x3.mdl"

ENT.CycleSeconds = 8       -- per stat, when none is chosen
ENT.ReadRange    = 1200    -- units; farther than this nobody can read it

function ENT:SetupDataTables()
    self:NetworkVar("String", 0, "Stat")   -- "" = cycle through all five
    self:NetworkVar("String", 1, "Bike")   -- "" = every bike
end
