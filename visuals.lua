-- battle_lobby/visuals.lua
-- Global-ish desaturation using texture modifiers on node tiles.

local bl  = battle_lobby or {}
bl.visuals = bl.visuals or {}
local vis = bl.visuals

vis.original_tiles = vis.original_tiles or {}
vis.enabled = vis.enabled or false

-- Fallback copy function
local function tbl_copy(t)
    local nt = {}
    for k,v in pairs(t or {}) do
        nt[k] = v
    end
    return nt
end

-- Build a “desaturated” version of a tile string
local function make_desat_str(tex)
    -- Tweak these to change the look (Legacy-ish mute)
    return tex .. "^[colorize:#808080:80^[multiply:#C0C0C0"
end

-- Build desaturated tiles array from an existing tiles definition
local function make_desat_tiles(def_tiles)
    if not def_tiles then return nil end

    local new_tiles = {}

    for i, t in ipairs(def_tiles) do
        if type(t) == "string" then
            new_tiles[i] = make_desat_str(t)
        elseif type(t) == "table" and t.name then
            local nt = tbl_copy(t)
            nt.name = make_desat_str(t.name)
            new_tiles[i] = nt
        else
            -- Unknown format, keep as-is
            new_tiles[i] = t
        end
    end

    return new_tiles
end

-- Toggle desaturation for *all* registered nodes
function bl.set_desaturation(enabled)
    if enabled and not vis.enabled then
        minetest.log("action", "[battle_lobby] Enabling desaturated visuals...")

        for nodename, def in pairs(minetest.registered_nodes) do
            if def.tiles and #def.tiles > 0 and not vis.original_tiles[nodename] then
                local desat = make_desat_tiles(def.tiles)
                if desat then
                    vis.original_tiles[nodename] = def.tiles
                    minetest.override_item(nodename, { tiles = desat })
                end
            end
        end

        vis.enabled = true

    elseif not enabled and vis.enabled then
        minetest.log("action", "[battle_lobby] Restoring original visuals...")

        for nodename, tiles in pairs(vis.original_tiles) do
            minetest.override_item(nodename, { tiles = tiles })
        end

        vis.original_tiles = {}
        vis.enabled = false
    end
end

--------------------------------------------------
-- Chat command to toggle it by hand
--------------------------------------------------

minetest.register_chatcommand("battle_desaturate", {
    privs = { server = true },
    params = "<on|off>",
    description = "Toggle global desaturation of node textures (Battle style).",
    func = function(name, param)
        param = (param or ""):lower()
        if param == "on" then
            bl.set_desaturation(true)
            minetest.chat_send_all("[Battle] Desaturated visuals enabled.")
        elseif param == "off" then
            bl.set_desaturation(false)
            minetest.chat_send_all("[Battle] Desaturated visuals disabled.")
        else
            if msg then
                msg(name, "Usage: /battle_desaturate <on|off>")
            else
                minetest.chat_send_player(name, "Usage: /battle_desaturate <on|off>")
            end
        end
    end,
})
