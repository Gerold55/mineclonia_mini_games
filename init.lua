-- battle_lobby/init.lua

battle_lobby = battle_lobby or {}
battle_lobby.modpath = minetest.get_modpath("battle_lobby")

local mp = battle_lobby.modpath

dofile(mp .. "/util.lua")
dofile(mp .. "/config.lua")
dofile(mp .. "/state.lua")
local chests = dofile(minetest.get_modpath("battle_lobby").."/chests.lua")
dofile(mp .. "/ui.lua")
dofile(mp .. "/battle_core.lua")
dofile(mp .. "/tumble_core.lua")
dofile(mp .. "/visuals.lua")
dofile(mp .. "/snowball.lua")
dofile(mp .. "/commands.lua")

minetest.log("action", "[battle_lobby] Loaded modular Battle/Tumble lobby.")

-- Prepare chests for an arena (detect + initial loot)
minetest.register_chatcommand("battle_test_init_chests", {
    privs = {server = true},
    params = "<arena_id>",
    description = "Prepare chests for an arena (detect + fill with initial loot).",
    func = function(name, param)
        local aid = param ~= "" and param or nil
        if not aid then
            return false, "Usage: /battle_test_init_chests <arena_id>"
        end

        if not config or not config.arenas or not config.arenas[aid] then
            return false, "Arena '"..aid.."' not found. Use /battle_add_arena and /battle_set_center first."
        end

        local arena = config.arenas[aid]
        chests.prepare_battle_chests(aid, arena)

        return true, "Prepared chests for arena '"..aid.."'."
    end,
})

-- Force one chest refill tick
minetest.register_chatcommand("battle_test_refill_tick", {
    privs = {server = true},
    params = "",
    description = "Force one chest refill tick (for testing).",
    func = function(name, param)
        battle = battle or {}
        battle.state = "running"

        chests.update_battle_chest_refills()
        return true, "Ran chest refill tick."
    end,
})

minetest.register_alias("default:pine_wood", "mcl_trees:wood_spruce")
-- Stairs
minetest.register_alias("stairs:stair_pine_wood", "mcl_stairs:stair_spruce")
minetest.register_alias("stairs:stair_pine_tree", "mcl_stairs:stair_log_spruce") -- if present

-- Slabs
minetest.register_alias("stairs:slab_pine_wood", "mcl_stairs:slab_spruce")
minetest.register_alias("stairs:slab_pine_tree", "mcl_stairs:slab_spruce_bark") -- if present
--minetest.register_alias("default:mese", "mcl_redstone_torch:redstoneblock") -- if present
minetest.register_alias("walls:cobble", "mcl_walls:cobble") -- if present

-- Convert Minetest Game lava to Mineclonia lava
minetest.register_alias("default:lava_source", "mcl_core:lava_source")
minetest.register_alias("default:lava_flowing", "mcl_core:lava_flowing")

minetest.register_alias("nether:brick", "mcl_nether:nether_brick")
minetest.register_alias("default:fence_wood", "mcl_fences:oak_fence")
minetest.register_alias("default:fence_pine_wood", "mcl_fences:spruce_fence")
minetest.register_alias("default:fence_rail_pine_wood", "mcl_fences:spruce_fence_gate")

minetest.register_alias("xdecor:stone_rune", "mcl_core:stonebrickcarved")
minetest.register_alias("xdecor:stone_tile", "mcl_core:stone_smooth")