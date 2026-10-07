--[[--------------------------------------------------------------------------
    gamemodes/bmx/gamemode/cl_scores.lua

    The client half of sv_scores.lua:

        bmx_scores        a panel: the top ten of each stat on this map, with
                          your own best, filterable by bike
        NEW BEST banner   across the top of the screen when you beat yourself
        BMX.ScoresCache   the last table the server sent, which the leaderboard
                          sign (entities/bmx_leaderboard) draws from

    THE BANNER IS ITS OWN HUDPaint HOOK, not code inside cl_hud.lua. It borrows
    that file's fonts and its bmx_hud switch and cinematic check, and nothing
    else, so the rider HUD can be redesigned (it is being, G21) without this
    needing to know, and the other way round.
----------------------------------------------------------------------------]]

BMX = BMX or {}
BMX.Scores = BMX.Scores or {}
local S = BMX.Scores

-- The same lists as the server's: the wire carries an index, not a name.
S.Stats  = { "combo", "trick", "grind", "manual", "air" }
S.Labels = { combo = "Best combo", trick = "Best trick", grind = "Longest grind",
             manual = "Longest manual", air = "Biggest air" }
S.Units  = { combo = "pts", trick = "pts", grind = "s", manual = "s", air = "s" }

local COL_FG   = Color(232, 236, 242)
local COL_DIM  = Color(150, 158, 170)
local COL_GOLD = Color(255, 214, 90)

function S.Format(stat, v)
    if S.Units[stat] == "s" then return string.format("%.2f s", v) end
    local s = tostring(math.floor(v))
    local out = s:reverse():gsub("(%d%d%d)", "%1,"):reverse()
    return (out:gsub("^,", "")) .. " pts"
end

--------------------------------------------------------------------------
-- The cache, and asking for it
--------------------------------------------------------------------------
-- cache = { bike = "", at = CurTime(), stats = { combo = { top = { {name, v, mine} }, mine = v }, ... } }
S.cache = S.cache or nil
BMX.ScoresCache = function() return S.cache end

function S.Request(bikeId)
    -- The server answers one request a second per player; a second ask inside
    -- that is simply dropped, so do not send it.
    if CurTime() < (S.nextAsk or 0) then return end
    S.nextAsk = CurTime() + 1.1
    net.Start("bmx_scores_req")
        net.WriteString(bikeId or "")
    net.SendToServer()
end

net.Receive("bmx_scores", function()
    local c = { bike = net.ReadString(), at = CurTime(), stats = {} }
    for _, stat in ipairs(S.Stats) do
        local top = {}
        for i = 1, net.ReadUInt(4) do
            top[i] = { name = net.ReadString(), v = net.ReadFloat(), mine = net.ReadBool() }
        end
        c.stats[stat] = { top = top, mine = net.ReadFloat() }
    end
    S.cache = c
    hook.Run("BMX_ScoresUpdated", c)
end)

--------------------------------------------------------------------------
-- NEW BEST
--------------------------------------------------------------------------
local banner = nil     -- { stat, v, at }

net.Receive("bmx_newbest", function()
    local stat = S.Stats[net.ReadUInt(3)] or "combo"
    banner = { stat = stat, v = net.ReadFloat(), at = CurTime() }
    if S.cache then S.cache.at = 0 end      -- the table you are looking at is stale now
    surface.PlaySound("buttons/button14.wav")
end)

hook.Add("HUDPaint", "BMX.NewBestPaint", function()
    local b = banner
    if not b then return end
    local age = CurTime() - b.at
    if age > 3.2 then banner = nil return end
    local cv = GetConVar("bmx_hud")
    if cv and not cv:GetBool() then return end
    if BMX.CinematicActive and BMX.CinematicActive(LocalPlayer()) then return end
    local a = 255 * (1 - math.max(0, (age - 2.4) / 0.8))
    local slide = math.min(1, age / 0.25)
    local y = ScrH() * 0.12 - (1 - slide) * 40
    draw.SimpleText("NEW BEST", "BMX.Big", ScrW() * 0.5, y,
        Color(COL_GOLD.r, COL_GOLD.g, COL_GOLD.b, a), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
    draw.SimpleText(S.Labels[b.stat] .. "  " .. S.Format(b.stat, b.v), "BMX.Small",
        ScrW() * 0.5, y + 28, Color(COL_FG.r, COL_FG.g, COL_FG.b, a),
        TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
end)

--------------------------------------------------------------------------
-- The panel
--------------------------------------------------------------------------
local frame

local function fill(list, stat)
    list:Clear()
    local s = S.cache and S.cache.stats[stat]
    if not s then return end
    for i, e in ipairs(s.top) do
        list:AddLine(i, e.name .. (e.mine and "  (you)" or ""), S.Format(stat, e.v))
    end
end

function S.OpenPanel()
    if IsValid(frame) then frame:Remove() end
    frame = vgui.Create("DFrame")
    frame:SetTitle("BMX scores -- " .. game.GetMap())
    frame:SetSize(520, 420)
    frame:Center()
    frame:MakePopup()

    local bikes = vgui.Create("DComboBox", frame)
    bikes:Dock(TOP)
    bikes:AddChoice("every bike", "", true)
    for _, id in ipairs(BMX.BikeIDs()) do bikes:AddChoice(id, id) end

    local sheet = vgui.Create("DPropertySheet", frame)
    sheet:Dock(FILL)
    local lists = {}
    for _, stat in ipairs(S.Stats) do
        local l = vgui.Create("DListView", sheet)
        l:AddColumn("#"):SetFixedWidth(30)
        l:AddColumn("Rider")
        l:AddColumn(S.Labels[stat])
        lists[stat] = l
        sheet:AddSheet(S.Labels[stat], l)
    end

    local mine = vgui.Create("DLabel", frame)
    mine:Dock(BOTTOM)
    mine:SetText("")
    mine:SetTall(22)

    local function refresh()
        for _, stat in ipairs(S.Stats) do fill(lists[stat], stat) end
        local line = {}
        for _, stat in ipairs(S.Stats) do
            local c = S.cache and S.cache.stats[stat]
            if c and c.mine > 0 then line[#line + 1] = S.Labels[stat] .. " " .. S.Format(stat, c.mine) end
        end
        mine:SetText("yours: " .. (#line > 0 and table.concat(line, "   ") or "nothing yet"))
    end

    function bikes:OnSelect(_, _, data) S.nextAsk = 0; S.Request(data) end
    hook.Add("BMX_ScoresUpdated", "BMX.ScoresPanel", function()
        if IsValid(frame) then refresh() else hook.Remove("BMX_ScoresUpdated", "BMX.ScoresPanel") end
    end)
    S.nextAsk = 0
    S.Request("")
    refresh()
end

concommand.Add("bmx_scores", S.OpenPanel)
