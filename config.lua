-- battle_lobby/config.lua

local bl = battle_lobby
bl.config = bl.config or {}
config = bl.config

--------------------------------------------------
-- LOOT POOLS
--------------------------------------------------

config.loot_pools = {
    -- Weapons / armor / good stuff for center chests in Cove
    cove_center_main = {
        { name="mcl_core:iron_sword",       weight=10, min=1, max=1 },
        { name="mcl_core:bow",              weight=8,  min=1, max=1 },
        { name="mcl_core:arrow",            weight=12, min=4, max=16 },
        { name="mcl_armor:iron_chestplate", weight=6,  min=1, max=1 },
        { name="mcl_armor:iron_helmet",     weight=6,  min=1, max=1 },
        { name="mcl_potions:healing",       weight=5,  min=1, max=2 },
        { name="mcl_core:golden_apple",     weight=3,  min=1, max=1 },
    },

    -- Food / utility
    cove_food = {
        { name="mcl_core:bread",            weight=10, min=1, max=4 },
        { name="mcl_core:apple",            weight=8,  min=1, max=3 },
        { name="mcl_core:steak",            weight=5,  min=1, max=3 },
    },

    -- Side chest stuff (weaker)
    cove_side_basic = {
        { name="mcl_core:wooden_sword",     weight=10, min=1, max=1 },
        { name="mcl_core:stone_sword",      weight=5,  min=1, max=1 },
        { name="mcl_core:arrow",            weight=6,  min=2, max=6 },
        { name="mcl_core:bread",            weight=9,  min=1, max=3 },
        { name="mcl_core:apple",            weight=7,  min=1, max=3 },
        { name="mcl_potions:healing",       weight=3,  min=1, max=1 },
    },

    -- Refills for center chests (slightly weaker than initial)
    cove_center_refill = {
        { name="mcl_core:stone_sword",      weight=10, min=1, max=1 },
        { name="mcl_core:bow",              weight=5,  min=1, max=1 },
        { name="mcl_core:arrow",            weight=12, min=4, max=8 },
        { name="mcl_core:bread",            weight=12, min=1, max=3 },
        { name="mcl_potions:swiftness",     weight=4,  min=1, max=1 },
    },
}

--------------------------------------------------
-- LOOT PROFILES
--------------------------------------------------

config.loot_profiles = {
    cove_center = {
        rolls = {
            { pool = "cove_center_main", count = 4 },
            { pool = "cove_food",        count = 2 },
        },
        refill_rolls = {
            { pool = "cove_center_refill", count = 4 },
            { pool = "cove_food",          count = 2 },
        },
        max_items = 18,
    },

    cove_side = {
        rolls = {
            { pool = "cove_side_basic", count = 4 },
            { pool = "cove_food",       count = 1 },
        },
        -- no refill_rolls -> uses same as initial
        max_items = 12,
    },
}

--------------------------------------------------
-- CUSTOM CHESTS
--------------------------------------------------

config.custom_chests = {
    {
        id          = "cove_center",
        node_name   = "battle_lobby:cove_center_chest",
        description = "Cove Center Chest",
        profile     = "cove_center",
        refill_time = 60,
    },
    {
        id          = "cove_side",
        node_name   = "battle_lobby:cove_side_chest",
        description = "Cove Side Chest",
        profile     = "cove_side",
        refill_time = 60,
    },

    -- Add more for other maps:
    -- { id="crucible_center", node_name="battle_lobby:crucible_center_chest", profile="crucible_center", refill_time=60 },
    -- { id="crucible_side",   node_name="battle_lobby:crucible_side_chest",   profile="crucible_side",   refill_time=60 },
}
