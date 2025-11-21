--------------------------------------------------------------------
-- battle_lobby / chests.lua
-- Handles Battle chests, loot, animations and refills.
--------------------------------------------------------------------

local M = {}

local MODNAME = minetest.get_current_modname()
local NODE_CHEST_CENTER = MODNAME .. ":chest_center"
local NODE_CHEST_OUTER  = MODNAME .. ":chest_outer"

local BATTLE_CHEST_REFILL_SECONDS = 10 -- in chests.lua for testing

--------------------------
-- Utility / Fallbacks  --
--------------------------

local function msg(name, text)
    if _G.msg then
        _G.msg(name, text)
    else
        minetest.chat_send_player(name, text)
    end
end

local function broadcast(text)
    if _G.broadcast then
        _G.broadcast(text)
    else
        minetest.chat_send_all(text)
    end
end

-- Ensure global config table exists
config = config or {}
config.arenas = config.arenas or {}

-----------------------------
-- Battle player detection --
-----------------------------
local function is_battle_player(name)
    return battle and battle.players and battle.players[name]
end

-----------------------------
-- Arena helper functions  --
-----------------------------
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

local function bl_get_arena(aid)
    if not aid then return nil end
    return get_or_create_arena(aid)
end

-----------------------------------
-- Special Battle Chest Variants --
-----------------------------------

local function register_battle_chest_variant(node_name, desc_suffix)
    local base = minetest.registered_nodes["mcl_chests:chest"]
    if not base then
        minetest.log("error", "[battle_lobby] mcl_chests:chest not found, cannot register " .. node_name)
        return
    end

    local def = {}
    for k, v in pairs(base) do
        def[k] = v
    end

    def.description = (base.description or "Chest") .. " (" .. desc_suffix .. ")"
    def.groups = def.groups or {}
    def.groups.battle_lobby_chest = 1
    if desc_suffix == "Center" then
        def.groups.battle_lobby_chest_center = 1
    else
        def.groups.battle_lobby_chest_center = 0
    end

    -- Use ":" prefix to bypass strict modname prefix checks,
    -- but still register the node as MODNAME:chest_center / MODNAME:chest_outer
    minetest.register_node(":" .. node_name, def)
end

-------------------------------
-- Chest inventory & UI      --
-------------------------------

local BATTLE_CHEST_INV_SIZE = 27  -- 9x3
local CHEST_FORMSPEC_PREFIX = MODNAME .. ":chest_"

local function ensure_chest_inventory(pos)
    local inv = minetest.get_inventory({ type = "node", pos = pos })
    if not inv then
        inv = minetest.get_meta(pos):get_inventory()
    end
    if inv:get_size("main") == 0 then
        inv:set_size("main", BATTLE_CHEST_INV_SIZE)
    end
    return inv
end

local function make_battle_chest_formspec(pos)
    local spos = ("%d,%d,%d"):format(pos.x, pos.y, pos.z)
    return "formspec_version[4]" ..
        "size[9,7]" ..
        "label[0.3,0.3;Chest]" ..
        "list[nodemeta:" .. spos .. ";main;0.5,0.8;9,3;]" ..
        "label[0.3,4.9;Hotbar]" ..
        "list[current_player;main;0.5,5.4;9,1;]" ..
        "listring[nodemeta:" .. spos .. ";main]" ..
        "listring[current_player;main]"
end

-----------------------------------------
-- Override chest rightclick (Battle)  --
-----------------------------------------

local function override_chest_for_battle(chest_name)
    local def = minetest.registered_nodes[chest_name]
    if not def then
        minetest.log("warning", "[battle_lobby] Chest node not found for override: " .. chest_name)
        return
    end

    local old_on_rightclick = def.on_rightclick

    minetest.override_item(chest_name, {
        on_rightclick = function(pos, node, clicker, itemstack, pointed_thing)
            local name = clicker and clicker:get_player_name()
            if name and is_battle_player(name) then
                ensure_chest_inventory(pos)

                local meta = minetest.get_meta(pos)
                meta:set_string("battle_lobby_orig_chest", node.name)

                local open_name = "mcl_chests:chest_open"
                if minetest.registered_nodes[open_name] then
                    minetest.swap_node(pos, { name = open_name, param2 = node.param2 })
                end

                minetest.sound_play("mcl_chests_chest_open", {
                    pos = pos,
                    gain = 0.3,
                    max_hear_distance = 16,
                }, true)

                minetest.show_formspec(
                    name,
                    CHEST_FORMSPEC_PREFIX .. minetest.pos_to_string(pos),
                    make_battle_chest_formspec(pos)
                )
                return itemstack
            end

            if old_on_rightclick then
                return old_on_rightclick(pos, node, clicker, itemstack, pointed_thing)
            end
            return itemstack
        end
    })
end

----------------------------------------
-- Chest close animation & sound      --
----------------------------------------

minetest.register_on_player_receive_fields(function(player, formname, fields)
    if formname:sub(1, #CHEST_FORMSPEC_PREFIX) ~= CHEST_FORMSPEC_PREFIX then
        return
    end

    if not fields.quit then
        return
    end

    local pos_str = formname:sub(#CHEST_FORMSPEC_PREFIX + 1)
    local pos = minetest.string_to_pos(pos_str)
    if not pos then return end

    local meta = minetest.get_meta(pos)
    local node = minetest.get_node(pos)
    local orig = meta:get_string("battle_lobby_orig_chest")

    if orig ~= "" and minetest.registered_nodes[orig] then
        minetest.swap_node(pos, { name = orig, param2 = node.param2 })
    end
    meta:set_string("battle_lobby_orig_chest", "")

    minetest.sound_play("mcl_chests_chest_close", {
        pos = pos,
        gain = 0.3,
        max_hear_distance = 16,
    }, true)
end)

------------------------
-- Loot Table System  --
------------------------

local loot_tables = {
    center_initial = {
        { item = "mcl_core:diamond_sword", max_count = 1,  weight = 2 },
        { item = "mcl_core:iron_sword",    max_count = 1,  weight = 4 },
        { item = "mcl_core:bow",           max_count = 1,  weight = 4 },
        { item = "mcl_core:arrow",         max_count = 16, weight = 6 },
        { item = "mcl_core:golden_apple",  max_count = 2,  weight = 3 },
        { item = "mcl_potions:healing",    max_count = 2,  weight = 3 },
        { item = "mcl_core:cooked_beef",   max_count = 6,  weight = 5 },
    },

    center_refill = {
        { item = "mcl_core:iron_sword",   max_count = 1,  weight = 3 },
        { item = "mcl_core:bow",          max_count = 1,  weight = 3 },
        { item = "mcl_core:arrow",        max_count = 12, weight = 6 },
        { item = "mcl_potions:healing",   max_count = 1,  weight = 3 },
        { item = "mcl_core:cooked_beef",  max_count = 4,  weight = 5 },
    },

    regular_initial = {
        { item = "mcl_core:stone_sword",        max_count = 1, weight = 5 },
        { item = "mcl_core:wood_sword",         max_count = 1, weight = 4 },
        { item = "mcl_core:cooked_porkchop",    max_count = 4, weight = 6 },
        { item = "mcl_core:apple",              max_count = 4, weight = 5 },
        { item = "mcl_core:leather_helmet",     max_count = 1, weight = 3 },
        { item = "mcl_core:leather_chestplate", max_count = 1, weight = 3 },
    },

    regular_refill = {
        { item = "mcl_core:stone_sword",     max_count = 1, weight = 3 },
        { item = "mcl_core:cooked_porkchop", max_count = 3, weight = 5 },
        { item = "mcl_core:apple",           max_count = 3, weight = 4 },
    },
}

local function random_pick_from_table(tbl)
    local total_weight = 0
    for _, e in ipairs(tbl) do
        total_weight = total_weight + (e.weight or 1)
    end
    if total_weight <= 0 then return nil end

    local r = math.random() * total_weight
    local acc = 0
    for _, e in ipairs(tbl) do
        acc = acc + (e.weight or 1)
        if r <= acc then
            return e
        end
    end
    return tbl[#tbl]
end

local function add_loot(inv, listname, tbl)
    if not tbl or #tbl == 0 then return end
    local size = inv:get_size(listname)
    if size <= 0 then return end

    local slots_to_fill = math.min(size, math.max(4, math.random(6, 10)))

    for _ = 1, slots_to_fill do
        local entry = random_pick_from_table(tbl)
        if entry then
            local stack = ItemStack(entry.item)
            local count = 1
            if entry.max_count and entry.max_count > 1 then
                count = math.random(1, entry.max_count)
            end
            stack:set_count(count)
            local idx = math.random(1, size)
            local old = inv:get_stack(listname, idx)
            if old:is_empty() then
                inv:set_stack(listname, idx, stack)
            end
        end
    end
end

local function loot_for_type(ctype, initial)
    if ctype == "center" then
        return initial and loot_tables.center_initial or loot_tables.center_refill
    else
        return initial and loot_tables.regular_initial or loot_tables.regular_refill
    end
end

----------------------------------------
-- Chest Preparation & Refill System  --
----------------------------------------

local BATTLE_CHEST_REFILL_SECONDS = 60

M.runtime = {
    chest_runtime = nil,
}

function M.prepare_battle_chests(arena_id, arena)
    if not battle then return end

    M.runtime.chest_runtime = { arena_id = arena_id, chests = {} }
    arena.chests = arena.chests or {}

    if (#arena.chests == 0) and arena.center and arena.radius then
        local center = arena.center
        local r      = arena.radius

        local minp = { x = center.x - r, y = center.y - 8, z = center.z - r }
        local maxp = { x = center.x + r, y = center.y + 8, z = center.z + r }

        local chest_nodes = {
            "mcl_chests:chest",
            "mcl_chests:trapped_chest",
            NODE_CHEST_CENTER,
            NODE_CHEST_OUTER,
        }

        local chest_positions = minetest.find_nodes_in_area(minp, maxp, chest_nodes)
        local center_radius = arena.center_chest_radius
            or math.max(4, math.floor(r * 0.3))

        arena.chests = {}

        for _, pos in ipairs(chest_positions) do
            local node = minetest.get_node(pos)
            local ctype

            if node.name == NODE_CHEST_CENTER then
                ctype = "center"
            elseif node.name == NODE_CHEST_OUTER then
                ctype = "regular"
            else
                local dx = pos.x - center.x
                local dz = pos.z - center.z
                local dist = math.sqrt(dx*dx + dz*dz)
                if dist <= center_radius then
                    ctype = "center"
                else
                    ctype = "regular"
                end
            end

            table.insert(arena.chests, {
                pos   = vector.new(pos),
                ctype = ctype,
            })
        end

        if save_config then
            save_config()
        end

        minetest.log("action", "[battle_lobby] Auto-detected "
            .. #arena.chests .. " chests for arena '" .. arena_id .. "'.")
    end

    if not arena.chests or #arena.chests == 0 then
        return
    end

    for idx, info in ipairs(arena.chests) do
        local pos   = info.pos
        local ctype = info.ctype or "regular"
        local node  = minetest.get_node(pos)
        if node and (node.name == "mcl_chests:chest"
                 or node.name == "mcl_chests:trapped_chest"
                 or node.name == NODE_CHEST_CENTER
                 or node.name == NODE_CHEST_OUTER) then

            local inv = minetest.get_inventory({ type = "node", pos = pos })
            if inv then
                if not inv:get_list("main") or inv:get_size("main") == 0 then
                    inv:set_size("main", BATTLE_CHEST_INV_SIZE)
                end

                inv:set_list("main", {})
                add_loot(inv, "main", loot_for_type(ctype, true))

                M.runtime.chest_runtime.chests[idx] = {
                    pos            = vector.new(pos),
                    ctype          = ctype,
                    next_refill_at = os.time() + BATTLE_CHEST_REFILL_SECONDS,
                }
            end
        end
    end
end

function M.update_battle_chest_refills()
    if not battle or battle.state ~= "running" then return end
    local rt = M.runtime.chest_runtime
    if not rt or not rt.chests then return end

    local now = os.time()
    for _, c in ipairs(rt.chests) do
        if c and now >= (c.next_refill_at or 0) then
            local inv = minetest.get_inventory({ type = "node", pos = c.pos })
            if inv and inv:get_list("main") then
                if inv:is_empty("main") then
                    add_loot(inv, "main", loot_for_type(c.ctype, false))
                    c.next_refill_at = now + BATTLE_CHEST_REFILL_SECONDS
                else
                    c.next_refill_at = now + 10
                end
            end
        end
    end
end

-----------------------------------
-- Debug / Admin Chat Commands   --
-----------------------------------

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

minetest.register_chatcommand("battle_debug_list_chests", {
    privs = { server = true },
    params = "<arena_id>",
    description = "List all registered Battle chests for an arena.",
    func = function(name, param)
        local aid = param:match("^(%S+)$")
        if not aid then
            return false, "Usage: /battle_debug_list_chests <arena_id>"
        end
        local arena = config.arenas and config.arenas[aid]
        if not arena or not arena.chests or #arena.chests == 0 then
            return true, "Arena '"..aid.."' has no chests registered."
        end

        msg(name, ("Arena '%s' has %d chests:"):format(aid, #arena.chests))
        for i,info in ipairs(arena.chests) do
            msg(name, (" #%d at %s (type=%s)"):format(
                i,
                minetest.pos_to_string(info.pos),
                info.ctype or "regular"
            ))
        end
        return true
    end,
})

minetest.register_chatcommand("battle_debug_empty_chests", {
    privs = { server = true },
    params = "<arena_id>",
    description = "Empty all Battle chests (main inventory) in an arena.",
    func = function(name, param)
        local aid = param:match("^(%S+)$")
        if not aid then
            return false, "Usage: /battle_debug_empty_chests <arena_id>"
        end

        local arena = bl_get_arena(aid)
        if not arena or not arena.chests then
            return false, "Arena '"..aid.."' does not exist or has no chests."
        end

        local cleared = 0
        for _,info in ipairs(arena.chests) do
            local inv = minetest.get_inventory({type="node", pos=info.pos})
            if inv then
                inv:set_list("main", {})
                cleared = cleared + 1
            end
        end

        return true, ("Emptied %d chests in arena '%s'."):format(cleared, aid)
    end,
})

minetest.register_chatcommand("battle_debug_fill_chests", {
    privs = { server = true },
    params = "<arena_id> <initial|refill>",
    description = "Fill all Battle chests with initial or refill loot, for testing.",
    func = function(name, param)
        local aid, mode = param:match("^(%S+)%s+(%S+)$")
        if not aid or not mode then
            return false, "Usage: /battle_debug_fill_chests <arena_id> <initial|refill>"
        end
        mode = mode:lower()
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
                if not inv:get_list("main") or inv:get_size("main") == 0 then
                    inv:set_size("main", BATTLE_CHEST_INV_SIZE)
                end
                inv:set_list("main", {})
                local loot_table = loot_for_type(info.ctype or "regular", initial)
                add_loot(inv, "main", loot_table)
                filled = filled + 1
            end
        end

        return true, ("Filled %d chests in arena '%s' using %s loot.")
            :format(filled, aid, mode)
    end,
})

----------------------------------
-- Init on mods loaded          --
----------------------------------

function M.register_all()
    if minetest.registered_nodes["mcl_chests:chest"] then
        register_battle_chest_variant(NODE_CHEST_CENTER, "Center")
        register_battle_chest_variant(NODE_CHEST_OUTER,  "Outer")
    end

    override_chest_for_battle("mcl_chests:chest")
    override_chest_for_battle("mcl_chests:trapped_chest")
    override_chest_for_battle(NODE_CHEST_CENTER)
    override_chest_for_battle(NODE_CHEST_OUTER)
end

minetest.register_on_mods_loaded(function()
    M.register_all()
end)

return M
