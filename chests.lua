-- battle_lobby/chests.lua
-- Custom 4J-style loot chests for Battle mode.

local bl  = battle_lobby or {}
local cfg = bl.config or {}

--------------------------------------------------
-- LOCAL COPY FUNCTION (NO DEPENDENCY ON util.lua)
--------------------------------------------------
local function tbl_copy(t)
    local nt = {}
    for k, v in pairs(t or {}) do
        nt[k] = v
    end
    return nt
end

--------------------------------------------------
-- WEIGHTED RANDOM + SHUFFLE
--------------------------------------------------

local function weighted_choice(pool)
    local total = 0
    for _, entry in ipairs(pool) do
        total = total + (entry.weight or 1)
    end
    if total <= 0 then return nil end

    local r = math.random() * total
    local acc = 0
    for _, entry in ipairs(pool) do
        acc = acc + (entry.weight or 1)
        if r <= acc then
            return entry
        end
    end
    return pool[#pool]
end

local function shuffle(list)
    for i = #list, 2, -1 do
        local j = math.random(1, i)
        list[i], list[j] = list[j], list[i]
    end
    return list
end

--------------------------------------------------
-- FILL CHEST FROM LOOT PROFILE
--------------------------------------------------

local function fill_chest_from_profile(pos, profile_name, is_refill)
    local loot_profiles = cfg.loot_profiles or {}
    local loot_pools    = cfg.loot_pools    or {}

    local profile = loot_profiles[profile_name]
    if not profile then
        minetest.log("warning", "[battle_lobby] Unknown loot profile: " .. tostring(profile_name))
        return
    end

    local rolls_def = profile.rolls
    if is_refill and profile.refill_rolls then
        rolls_def = profile.refill_rolls
    end
    if not rolls_def or #rolls_def == 0 then return end

    local meta = minetest.get_meta(pos)
    local inv  = meta:get_inventory()
    inv:set_size("main", 27) -- 9x3
    inv:set_list("main", {})

    local slots = {}
    for i = 1, 27 do slots[i] = i end
    shuffle(slots)

    local slot_index  = 1
    local max_items   = profile.max_items or 27
    local items_added = 0

    for _, roll in ipairs(rolls_def) do
        local pool  = loot_pools[roll.pool]
        local count = roll.count or 1
        if pool and #pool > 0 then
            for _ = 1, count do
                if items_added >= max_items or slot_index > #slots then
                    return
                end

                local entry = weighted_choice(pool)
                if entry then
                    local cmin   = entry.min or 1
                    local cmax   = entry.max or cmin
                    local amount = math.random(cmin, cmax)
                    local stack  = ItemStack(entry.name .. " " .. amount)

                    local slot = slots[slot_index]
                    slot_index = slot_index + 1
                    inv:set_stack("main", slot, stack)
                    items_added = items_added + 1
                end
            end
        else
            minetest.log("warning",
                "[battle_lobby] Loot profile '" .. profile_name ..
                "' refers to unknown or empty pool '" .. tostring(roll.pool) .. "'"
            )
        end
    end
end

--------------------------------------------------
-- FORMSPEC (CHEST + HOTBAR ONLY, MINECLONIA LOOK)
--------------------------------------------------

local function make_custom_chest_formspec(pos)
    local spos = ("%d,%d,%d"):format(pos.x, pos.y, pos.z)

    return "formspec_version[4]" ..
        "size[9,7]" ..
        "bgcolor[#080808BB;true]" ..
        "background9[0,0;9,7;mcl_inventory_bg.png;true;10]" ..
        "label[0.3,0.3;Chest]" ..
        "list[nodemeta:" .. spos .. ";main;0.5,0.8;9,3;]" ..
        "label[0.3,4.9;Hotbar]" ..
        "list[current_player;main;0.5,5.4;9,1;]" ..
        "listring[nodemeta:" .. spos .. ";main]" ..
        "listring[current_player;main]"
end

--------------------------------------------------
-- REGISTER CUSTOM CHESTS (DIRECTLY, NO on_mods_loaded)
--------------------------------------------------

local base = minetest.registered_nodes["mcl_chests:chest"]
if not base then
    minetest.log("error", "[battle_lobby] mcl_chests:chest not found. Did you add 'depends = mcl_chests' to mod.conf?")
    return
end

local custom_chests = cfg.custom_chests or {}
if #custom_chests == 0 then
    minetest.log("action", "[battle_lobby] No custom_chests defined in config.lua.")
    return
end

for _, def in ipairs(custom_chests) do
    if not def.node_name then
        minetest.log("warning", "[battle_lobby] custom chest missing node_name, id=" .. tostring(def.id))
    else
        local node_def = tbl_copy(base)

        node_def.description = def.description or ("Battle Chest (" .. tostring(def.id or "?") .. ")")
        node_def.groups      = tbl_copy(base.groups or {})
        node_def.drop        = def.node_name

        local profile_name = def.profile
        local refill_time  = def.refill_time or 60

        node_def.on_construct = function(pos)
            local meta = minetest.get_meta(pos)
            local inv  = meta:get_inventory()
            inv:set_size("main", 27)
            meta:set_string("infotext", def.description or "Battle Chest")

            fill_chest_from_profile(pos, profile_name, false)

            if refill_time > 0 then
                minetest.get_node_timer(pos):start(refill_time)
            end
        end

        node_def.on_timer = function(pos, elapsed)
            local meta = minetest.get_meta(pos)
            local inv  = meta:get_inventory()
            if inv and inv:is_empty("main") then
                fill_chest_from_profile(pos, profile_name, true)
            end
            return true
        end

        local old_on_rightclick = base.on_rightclick
        node_def.on_rightclick = function(pos, node, clicker, itemstack, pointed_thing)
            local name = clicker and clicker:get_player_name() or nil
            if name and bl.is_battle_player and bl.is_battle_player(name) then
                minetest.show_formspec(
                    name,
                    "battle_lobby:custom_chest_" .. minetest.pos_to_string(pos),
                    make_custom_chest_formspec(pos)
                )
                return itemstack
            end
            if old_on_rightclick then
                return old_on_rightclick(pos, node, clicker, itemstack, pointed_thing)
            end
            return itemstack
        end

        minetest.register_node(def.node_name, node_def)
        minetest.log("action", "[battle_lobby] Registered custom battle chest: " .. def.node_name)
    end
end
