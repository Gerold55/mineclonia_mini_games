-- battle_lobby/ui.lua

local bl = battle_lobby
local battle = bl.battle
local tumble = bl.tumble

--------------------------------------------------
-- BATTLE INVENTORY FORM (armor + model + hotbar)
--------------------------------------------------

local function battle_get_inventory_formspec(player)
    return
        "formspec_version[4]" ..
        "size[9,9]" ..
        "label[0.3,0.3;Battle Inventory]" ..
        "image[3.5,0.8;2.5,3.5;mcl_inventory_character.png]" ..
        "label[0.3,0.8;Armor]" ..
        "list[current_player;armor_head;0.5,1.3;1,1;]" ..
        "list[current_player;armor_torso;0.5,2.4;1,1;]" ..
        "list[current_player;armor_legs;0.5,3.5;1,1;]" ..
        "list[current_player;armor_feet;0.5,4.6;1,1;]" ..
        "label[0.3,6.4;Hotbar]" ..
        "list[current_player;main;0.5,6.9;9,1;]" ..
        "listring[current_player;main]" ..
        "listring[current_player;armor_head]" ..
        "listring[current_player;armor_torso]" ..
        "listring[current_player;armor_legs]" ..
        "listring[current_player;armor_feet]"
end

--------------------------------------------------
-- MAP VOTE FORMSPEC (simple placeholder)
--------------------------------------------------

function bl.show_map_vote_formspec(name)
    -- Simple placeholder: list arenas, click to vote
    local fs = "formspec_version[4]size[8,7]"
        .. "label[0.3,0.3;Vote for Battle Map]"
    local y = 1.0
    for aid, a in pairs(config.arenas) do
        if a.enabled ~= false then
            fs = fs .. ("button[0.5,%f;7,0.8;bvote_%s;%s]"):format(
                y, aid, a.label or aid
            )
            y = y + 0.9
        end
    end
    minetest.show_formspec(name, "battle_lobby:vote", fs)
end

--------------------------------------------------
-- PLAY MENU FORMSPEC
--------------------------------------------------

function bl.show_play_menu(name)
    local fs =
        "formspec_version[4]size[6,4]" ..
        "label[0.3,0.3;Choose Minigame]" ..
        "button[0.5,1.0;5,0.8;play_battle;Battle]" ..
        "button[0.5,2.1;5,0.8;play_tumble;Tumble]"
    minetest.show_formspec(name, "battle_lobby:play_menu", fs)
end

minetest.register_chatcommand("play", {
    description = "Open Battle/Tumble play menu.",
    func = function(name)
        bl.show_play_menu(name)
    end,
})

--------------------------------------------------
-- PLAYER FORMSPEC HANDLER
--------------------------------------------------

minetest.register_on_player_receive_fields(function(player, formname, fields)
    if not player then return end
    local name = player:get_player_name()
    if not name then return end

    -- Intercept Mineclonia inventory when in Battle
    if formname:sub(1,14) == "mcl_inventory:" then
        if battle.state == "running" and battle.players[name] then
            local fs = battle_get_inventory_formspec(player)
            minetest.show_formspec(name, "battle_lobby:inventory", fs)
            return true
        end
        return
    end

    if formname == "battle_lobby:inventory" then
        -- no extra fields yet
        return false
    end

    if formname == "battle_lobby:vote" then
        for field,_ in pairs(fields) do
            if field:sub(1,6) == "bvote_" then
                local aid = field:sub(7)
                local a = config.arenas[aid]
                if a and a.enabled ~= false then
                    battle.votes = battle.votes or {}
                    battle.votes[name] = aid
                    msg(name, "You voted for " .. (a.label or aid))
                    minetest.after(0.05, function()
                        bl.show_map_vote_formspec(name)
                    end)
                else
                    msg(name, "Arena not available.")
                end
                return true
            end
        end
    end

    if formname == "battle_lobby:play_menu" then
        if fields.play_battle then
            minetest.chatcommands["battle_join"].func(name, "")
            return true
        elseif fields.play_tumble then
            minetest.chatcommands["tumble_join"].func(name, "")
            return true
        end
    end
end)
