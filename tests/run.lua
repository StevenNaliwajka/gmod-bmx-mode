--[[--------------------------------------------------------------------------
    tests/run.lua

    BMX (Mode)'s offline suite, on the BMX vehicle addon's harness: the addon's Garry's
    Mod shim boots the real addon, then this repository's files on top, the
    way the engine would, and the tests here run against both.

        lua5.1 tests/run.lua            every test
        lua5.1 tests/run.lua city       only tests whose name or file matches

    The addon checkout is $BMX_ADDON, else ../gmod-bmx next to this
    repository, else tests/.addon (where CI clones it).
----------------------------------------------------------------------------]]

local here = (arg and arg[0] or "tests/run.lua"):match("^(.*)/[^/]*$") or "."
local root = here .. "/.."

local function isAddon(dir)
    local f = dir and io.open(dir .. "/tests/run.lua", "r")
    if f then f:close() return true end
    return false
end
local addon = os.getenv("BMX_ADDON")
if not isAddon(addon) then addon = root .. "/../gmod-bmx" end
if not isAddon(addon) then addon = here .. "/.addon" end
if not isAddon(addon) then
    io.stderr:write("no BMX addon checkout: set BMX_ADDON, or clone gmod/gmod-bmx next to this repository\n")
    os.exit(2)
end

BMX_SUITE = {
    tests = here,
    roots = { root .. "/gamemodes/bmx/gamemode", root .. "/gamemodes/bmx/entities" },
    boot = { function(R) R:loadGamemode("bmx") R:loadEntity("bmx_leaderboard") end },
}

package.path = here .. "/?.lua;" .. package.path
arg[0] = addon .. "/tests/run.lua"
dofile(arg[0])
