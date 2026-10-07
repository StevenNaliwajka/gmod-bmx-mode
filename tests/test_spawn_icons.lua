--[[--------------------------------------------------------------------------
    Every spawn-menu entry this gamemode adds has a picture.

    The rule is the BMX addon's (its tests/test_spawn_icons.lua and
    tools/icons/README.md): nobody picks a Q-menu entry from its name alone. A
    gamemode's own content lives in gamemodes/bmx/content/, which the engine
    mounts, so the icon for entities/<class> is
    gamemodes/bmx/content/materials/entities/<class>.png, 128x128. The pictures
    are shot in game with the addon's icon studio (tools/icons/shoot.sh there).
----------------------------------------------------------------------------]]

local gmod = require("lib.gmod")

-- tests/run.lua hands the addon's runner this repository's folders (BMX_SUITE.roots);
-- arg[0] is the addon's runner by now, so the gamemode is found from those.
local GM = BMX_SUITE.roots[2]:gsub("/entities$", "")
local ICONS = GM .. "/content/materials/entities/"

local function slurp(path)
    local fh = io.open(path, "r")
    if not fh then return "" end
    local s = fh:read("*a")
    fh:close()
    return s
end

-- Every entity or weapon folder/file under the gamemode that says Spawnable = true.
local function spawnable()
    local out = {}
    for _, kind in ipairs({ "entities", "weapons" }) do
        local p = io.popen('ls "' .. GM .. "/entities/" .. kind .. '" 2>/dev/null')
        for name in p:lines() do
            local class = name:gsub("%.lua$", "")
            local base = GM .. "/entities/" .. kind .. "/" .. name
            local src = name:match("%.lua$") and slurp(base)
                or (slurp(base .. "/shared.lua") .. slurp(base .. "/init.lua") .. slurp(base .. "/cl_init.lua"))
            if src:match("[%w_]+%.Spawnable%s*=%s*true") then out[#out + 1] = class end
        end
        p:close()
    end
    table.sort(out)
    return out
end

local function pngSize(path)
    local fh = io.open(path, "rb")
    if not fh then return nil end
    local head = fh:read(24) or ""
    fh:close()
    if head:sub(1, 8) ~= "\137PNG\r\n\26\n" then return nil end
    local function u32(i)
        local a, b, c, d = head:byte(i, i + 3)
        return ((a * 256 + b) * 256 + c) * 256 + d
    end
    return u32(17), u32(21)
end

T.test("spawn icons: the gamemode's spawnable entries are found (the leaderboard at least)", function()
    local list = spawnable()
    local found = false
    for _, c in ipairs(list) do if c == "bmx_leaderboard" then found = true end end
    T.ok(found, "bmx_leaderboard is spawnable: " .. table.concat(list, ", "))
end)

T.test("spawn icons: every spawnable entry has a 128x128 PNG picture", function()
    local missing = {}
    for _, class in ipairs(spawnable()) do
        local w, h = pngSize(ICONS .. class .. ".png")
        if w ~= 128 or h ~= 128 then missing[#missing + 1] = class .. (w and (" (" .. w .. "x" .. h .. ")") or "") end
    end
    T.eq(#missing, 0, "no 128x128 picture in content/materials/entities: " .. table.concat(missing, ", "))
end)
