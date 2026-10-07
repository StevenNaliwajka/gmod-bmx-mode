--[[--------------------------------------------------------------------------
    gamemodes/bmx/gamemode/cl_games.lua

    The HUD panel for whatever game you are in (sv_games.lua). One generic
    panel, fed a snapshot the server's game builds:

        { id, name, state, left, msg, rows = { { name, text, hi, out } } }

    so a new game never means new client code. Top left, under nothing: the
    rider HUD is bottom right and the trick callouts are centre.

    An empty snapshot clears it (you left, or the game was cancelled).
----------------------------------------------------------------------------]]

BMX = BMX or {}
BMX.GameHUD = BMX.GameHUD or {}

local snap = nil
local gotAt = 0

net.Receive("bmx_game", function()
    local json = net.ReadString()
    snap = json ~= "" and util.JSONToTable(json) or nil
    gotAt = CurTime()
end)

BMX.GameHUD.Get = function() return snap end

local COL_BG   = Color(16, 18, 22, 205)
local COL_FG   = Color(232, 236, 242)
local COL_DIM  = Color(150, 158, 170)
local COL_HI   = Color(255, 214, 90)
local COL_OUT  = Color(238, 105, 85)

local function clock(s)
    s = math.max(0, math.floor(s + 0.5))
    return string.format("%d:%02d", math.floor(s / 60), s % 60)
end

hook.Add("HUDPaint", "BMX.GamePaint", function()
    local g = snap
    if not g then return end
    local cv = GetConVar("bmx_hud")
    if cv and not cv:GetBool() then return end

    local rows = g.rows or {}
    local w, h = 270, 64 + #rows * 22
    local x, y = 28, 28
    draw.RoundedBox(6, x, y, w, h, COL_BG)

    draw.SimpleText(g.name or "BMX", "BMX.Small", x + 12, y + 8, COL_FG, TEXT_ALIGN_LEFT, TEXT_ALIGN_TOP)
    -- The server's clock is a snapshot at the moment it was sent, so count it
    -- down locally between snapshots rather than stepping once a second.
    if g.left then
        draw.SimpleText(clock(g.left - (CurTime() - gotAt)), "BMX.Big", x + w - 12, y + 2,
            g.state == "lobby" and COL_DIM or COL_HI, TEXT_ALIGN_RIGHT, TEXT_ALIGN_TOP)
    end
    draw.SimpleText(g.state == "lobby" and "lobby: waiting for players" or (g.msg or ""),
        "BMX.Small", x + 12, y + 32, COL_DIM, TEXT_ALIGN_LEFT, TEXT_ALIGN_TOP)

    for i, r in ipairs(rows) do
        local ry = y + 58 + (i - 1) * 22
        local col = r.out and COL_OUT or (r.hi and COL_HI or COL_FG)
        draw.SimpleText(r.name, "BMX.Small", x + 12, ry, col, TEXT_ALIGN_LEFT, TEXT_ALIGN_TOP)
        draw.SimpleText(r.text or "", "BMX.Small", x + w - 12, ry, col, TEXT_ALIGN_RIGHT, TEXT_ALIGN_TOP)
    end
end)
