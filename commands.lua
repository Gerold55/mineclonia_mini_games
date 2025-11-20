-- Global battle_lobby config table
config = config or {}
config.arenas = config.arenas or {}

local function get_or_create_arena(aid)
    config.arenas = config.arenas or {}
    local arena = config.arenas[aid]
    if not arena then
        arena = {
            label   = aid,
            enabled = true,
        }
        config.arenas[aid] = arena
        if save_config then
            save_config()
        end
        minetest.log("action", "[battle_lobby] Created new arena '"..aid.."' in config.")
    end
    return arena
end

minetest.register_chatcommand("battle_add_arena", {
    privs = { server = true },
    params = "<arena_id>",
    description = "Create or enable a Battle arena id.",
    func = function(name, param)
        local aid = param:match("^(%S+)$")
        if not aid then
            return false, "Usage: /battle_add_arena <arena_id>"
        end
        local arena = get_or_create_arena(aid)
        arena.enabled = true
        if save_config then save_config() end
        return true, "Arena '"..aid.."' created/enabled."
    end,
})

minetest.register_chatcommand("battle_set_center", {
    privs = { server = true },
    params = "<arena_id>",
    description = "Set arena center to your current position.",
    func = function(name, param)
        local aid = param:match("^(%S+)$")
        if not aid then
            return false, "Usage: /battle_set_center <arena_id>"
        end
        local player = minetest.get_player_by_name(name)
        if not player then return false, "Player not found." end

        local pos = vector.round(player:get_pos())
        local arena = get_or_create_arena(aid)
        arena.center = pos
        if save_config then save_config() end

        return true, "Arena '"..aid.."' center set to "..minetest.pos_to_string(pos).."."
    end,
})

minetest.register_chatcommand("battle_set_radius", {
    privs = { server = true },
    params = "<arena_id> <radius>",
    description = "Set arena radius (used for chest auto-detect and edge checks).",
    func = function(name, param)
        local aid, r = param:match("^(%S+)%s+(%d+)$")
        if not aid or not r then
            return false, "Usage: /battle_set_radius <arena_id> <radius>"
        end
        r = tonumber(r)
        local arena = get_or_create_arena(aid)
        arena.radius = r
        if save_config then save_config() end

        return true, "Arena '"..aid.."' radius set to "..r.."."
    end,
})

minetest.register_chatcommand("remove_unknown", {
    params = "<radius>",
    description = "Remove unknown nodes in a cube around you (admin only).",
    privs = { server = true },
    func = function(name, param)
        local player = minetest.get_player_by_name(name)
        if not player then
            return false, "Player not found."
        end

        local r = tonumber(param)
        if not r or r <= 0 then
            return false, "Usage: /remove_unknown <radius> (positive number)"
        end

        -- Clamp radius a bit so you don't accidentally nuke half the map
        if r > 50 then
            r = 50
            minetest.chat_send_player(name, "Radius clamped to 50 to avoid lag.")
        end

        local pos = vector.round(player:get_pos())
        local minp = vector.subtract(pos, r)
        local maxp = vector.add(pos, r)

        local t0 = minetest.get_us_time()

        local vm = minetest.get_voxel_manip()
        local emin, emax = vm:read_from_map(minp, maxp)
        local area = VoxelArea:new{ MinEdge = emin, MaxEdge = emax }
        local data = vm:get_data()

        local c_air = minetest.get_content_id("air")

        local removed = 0
        local seen_ids = {}

        for vi in area:iter(emin.x, emin.y, emin.z, emax.x, emax.y, emax.z) do
            local cid = data[vi]

            -- Cache lookups by content ID
            local info = seen_ids[cid]
            if info == nil then
                local nname = minetest.get_name_from_content_id(cid)
                -- unknown if no name OR not registered as a node
                if not nname or not minetest.registered_nodes[nname] then
                    info = "unknown"
                else
                    info = "ok"
                end
                seen_ids[cid] = info
            end

            if info == "unknown" then
                data[vi] = c_air
                removed = removed + 1
            end
        end

        vm:set_data(data)
        vm:write_to_map()
        vm:update_map()

        local dt = (minetest.get_us_time() - t0) / 1e6
        minetest.chat_send_player(name,
            ("Removed %d unknown nodes in radius %d (%.2f s)")
            :format(removed, r, dt))

        return true
    end,
})

--------------------------------------------------------------------
-- DEBUG COMMANDS FOR TESTING CHESTS / LOOT RELOAD SYSTEM
--------------------------------------------------------------------

-- Helper to fetch arena safely
local function bl_get_arena(aid)
    if not config or not config.arenas then return nil end
    return config.arenas[aid]
end


-----------------------------
-- 1) LIST CHESTS
-----------------------------
minetest.register_chatcommand("battle_debug_list_chests", {
    privs = { server = true },
    params = "<arena_id>",
    description = "Lists all registered chests for an arena, including center/regular type.",
    func = function(name, param)
        local aid = param:match("^(%S+)$")
        if not aid then
            return false, "Usage: /battle_debug_list_chests <arena_id>"
        end

        local arena = bl_get_arena(aid)
        if not arena then
            return false, "Arena '"..aid.."' does not exist."
        end
        
        arena.chests = arena.chests or {}
        if #arena.chests == 0 then
            return true, "Arena '"..aid.."' has no registered chests."
        end
        
        minetest.chat_send_player(name, "Chests for arena '"..aid.."':")
        for i,info in ipairs(arena.chests) do
            minetest.chat_send_player(name,
                (" #%d at %s type=%s"):
                    format(i, minetest.pos_to_string(info.pos), info.ctype or "regular"))
        end

        return true
    end
})


-----------------------------
-- 2) EMPTY ALL CHESTS
-----------------------------
minetest.register_chatcommand("battle_debug_empty_chests", {
    privs = { server = true },
    params = "<arena_id>",
    description = "Empties all chest inventories for an arena.",
    func = function(name, param)
        local aid = param:match("^(%S+)$")
        if not aid then
            return false, "Usage: /battle_debug_empty_chests <arena_id>"
        end
        
        local arena = bl_get_arena(aid)
        if not arena or not arena.chests then
            return false, "Arena '"..aid.."' does not exist or has no chests."
        end
        
        local count = 0
        for _,info in ipairs(arena.chests) do
            local inv = minetest.get_inventory({type="node", pos=info.pos})
            if inv then
                inv:set_list("main", {})
                count = count + 1
            end
        end
        
        return true, "Emptied "..count.." chests in arena '"..aid.."'."
    end
})


-----------------------------
-- 3) MANUALLY FILL CHESTS
-----------------------------
minetest.register_chatcommand("battle_debug_fill_chests", {
    privs = { server = true },
    params = "<arena_id> <initial|refill>",
    description = "Fills all arena chests using either the initial or refill loot table.",
    func = function(name, param)
        local aid, mode = param:match("^(%S+)%s+(%S+)$")
        if not aid or not mode then
            return false, "Usage: /battle_debug_fill_chests <arena_id> <initial|refill>"
        end

        local initial = (mode == "initial")
        if not initial and mode ~= "refill" then
            return false, "Second argument must be 'initial' or 'refill'."
        end
        
        local arena = bl_get_arena(aid)
        if not arena or not arena.chests then
            return false, "Arena '"..aid.."' does not exist or has no chests."
        end
        
        local filled = 0
        for _,info in ipairs(arena.chests) do
            local inv = minetest.get_inventory({type="node", pos=info.pos})
            if inv then
                inv:set_list("main", {})
                local loot_table = loot_for_type(info.ctype, initial)
                add_loot(inv, "main", loot_table)
                filled = filled + 1
            end
        end
        
        return true, "Filled "..filled.." chests in arena '"..aid.."' using "..mode.." loot."
    end
})
