--[[--------------------------------------------------------------------------
    The Steam Workshop upload (gmod-bmx tools/workshop_sync.py packs
    this repository with Garry's Mod's own gmad and uploads it): what Steam
    takes from it must be right before it goes.

      - the item page's text is addon.json's `description` (gmad writes it into
        the .gma and gmpublish create takes it from there), and
        workshop/description.bbcode is the copy people edit and preview: the
        two say the same, word for word
      - the icon is a real 512x512 JPEG (Steam refuses a PNG named .jpg, and
        512x513)
      - the title, type and tags are ones Steam accepts
----------------------------------------------------------------------------]]

local here = debug.getinfo(1, "S").source:match("^@(.*)/[^/]*$") or "tests"
local root = here .. "/.."

local function read(p)
    local f = assert(io.open(root .. "/" .. p, "rb"))
    local s = f:read("*a")
    f:close()
    return s
end

-- the JSON string value of "key" in addon.json (escapes undone)
local function jsonString(src, key)
    local s = src:match('"' .. key .. '"%s*:%s*"(.-[^\\])"%s*[,}\n]')
    if not s then return nil end
    s = s:gsub("\\u(%x%x%x%x)", function(h) return string.char(tonumber(h, 16) % 256) end)
    s = s:gsub("\\(.)", { n = "\n", t = "\t", ['"'] = '"', ["\\"] = "\\", ["/"] = "/" })
    return s
end

T.test("workshop: the page text in addon.json is workshop/description.bbcode, word for word", function()
    local json = read("addon.json")
    local desc = jsonString(json, "description")
    T.ok(desc, "addon.json has a description")
    local bb = read("workshop/description.bbcode"):gsub("\n+$", "")
    T.eq(desc, bb, "addon.json description = workshop/description.bbcode")
    T.ok(#bb > 400 and bb:find("[h1]", 1, true), "a real page, with a heading")
end)

T.test("workshop: title, type and tags are ones Steam takes", function()
    local json = read("addon.json")
    local title = jsonString(json, "title")
    T.ok(title and #title >= 3 and #title <= 128, "title: " .. tostring(title))
    local kind = jsonString(json, "type")
    local TYPES = { gamemode = 1, map = 1, weapon = 1, vehicle = 1, npc = 1, entity = 1, tool = 1, effects = 1, model = 1, servercontent = 1 }
    T.ok(TYPES[kind], "type " .. tostring(kind))
    local TAGS = { fun = 1, roleplay = 1, scenic = 1, movie = 1, realism = 1, cartoon = 1, water = 1, comic = 1, build = 1 }
    local tags = json:match('"tags"%s*:%s*(%b[])')
    T.ok(tags, "has tags")
    local n = 0
    for t in (tags or ""):gmatch('"([^"]+)"') do n = n + 1 T.ok(TAGS[t], "tag " .. t) end
    T.ok(n >= 1 and n <= 2, "one or two tags: " .. n)
    T.ok(json:find('"workshop/%*"'), "workshop/ is kept out of the .gma")
end)

T.test("workshop: the icon is a 512x512 JPEG under 1 MB", function()
    local j = read("workshop/icon.jpg")
    T.ok(#j < 1024 * 1024, "under 1 MB: " .. #j)
    T.eq(j:byte(1), 0xFF, "JPEG magic") T.eq(j:byte(2), 0xD8, "JPEG magic")
    -- walk the markers to the frame header (SOF0..SOF15, not DHT/JPG/DAC)
    local i, w, h = 3, nil, nil
    while i < #j do
        if j:byte(i) ~= 0xFF then break end
        local m = j:byte(i + 1)
        local len = j:byte(i + 2) * 256 + j:byte(i + 3)
        if m >= 0xC0 and m <= 0xCF and m ~= 0xC4 and m ~= 0xC8 and m ~= 0xCC then
            h = j:byte(i + 5) * 256 + j:byte(i + 6)
            w = j:byte(i + 7) * 256 + j:byte(i + 8)
            break
        end
        i = i + 2 + len
    end
    T.eq(w, 512, "width") T.eq(h, 512, "height")
end)

-- Players report bugs and ideas on the public GitHub copy (Issues on), so the page
-- links this repository's own issue tracker.
T.test("workshop: the page links this repository's GitHub issues", function()
    local bb = read("workshop/description.bbcode")
    T.ok(bb:find("[url=https://github.com/StevenNaliwajka/gmod-bmx-mode/issues]", 1, true), "links github.com/StevenNaliwajka/gmod-bmx-mode/issues")
end)
