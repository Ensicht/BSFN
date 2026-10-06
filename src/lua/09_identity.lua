-- =============================================================================
-- 对象遍历与玩家隔离
-- =============================================================================
-- 有界子对象遍历；所有玩家含晚到的联机副本在自动匹配前排除。

local function collect_child_game_objects(root_obj)
    local result = {}
    local limit = tonumber(config.max_recursive_children) or 128
    local function visit(game_obj, depth)
        if not game_obj or #result >= limit or depth > 5 then
            return
        end
        table.insert(result, game_obj)
        local transform = get_transform(game_obj)
        if not transform then
            return
        end
        local ok_child, child = safe_call(transform, "get_Child")
        while ok_child and child and #result < limit do
            local ok_obj, child_obj = safe_call(child, "get_GameObject")
            if ok_obj and child_obj then
                visit(child_obj, depth + 1)
            end
            ok_child, child = safe_call(child, "get_Next")
        end
    end
    visit(root_obj, 0)
    return result
end

local function build_npc_id_value_map()
    if npc_id_by_value then
        return npc_id_by_value
    end
    npc_id_by_value = {}
    local td = safe_sdk_type("app.NpcDef.ID")
    if not td then
        return npc_id_by_value
    end
    local ok_fields, fields = pcall(function()
        return td:get_fields()
    end)
    if not ok_fields or type(fields) ~= "table" then
        return npc_id_by_value
    end
    for _, field in pairs(fields) do
        local ok_name, name = pcall(function()
            return field:get_name()
        end)
        local ok_value, value = pcall(function()
            return field:get_data()
        end)
        name = ok_name and tostring(name or "") or ""
        local number = ok_value and (tonumber(value) or tonumber(tostring(value))) or nil
        if number and string.match(name, "^NPC%d+_%d+_%d+$") then
            npc_id_by_value[number] = name
        end
    end
    return npc_id_by_value
end

local function npc_id_from_serializable(value)
    if value == nil then
        return nil
    end
    local direct = string.match(tostring(value), "NPC%d+_%d+_%d+")
    if direct then
        return direct
    end
    local candidates = { value }
    for _, field_name in ipairs({ "_Value", "value__" }) do
        local ok, candidate = safe_field(value, field_name)
        if ok and candidate ~= nil then
            table.insert(candidates, candidate)
        end
    end
    for _, method_name in ipairs({ "get_Value", "get_value" }) do
        local ok, candidate = safe_call(value, method_name)
        if ok and candidate ~= nil then
            table.insert(candidates, candidate)
        end
    end
    local value_map = build_npc_id_value_map()
    for _, candidate in ipairs(candidates) do
        local text_value = tostring(candidate or "")
        local npc_id = string.match(text_value, "NPC%d+_%d+_%d+")
        if npc_id then
            return npc_id
        end
        local number = tonumber(candidate) or tonumber(text_value)
        if number and value_map[number] then
            return value_map[number]
        end
    end
    return nil
end
local function read_npc_id(character, root_obj)
    local values = {
        tostring(character or ""),
        tostring(root_obj or ""),
        get_game_object_name(root_obj)
    }
    for _, field_name in ipairs({ "_NpcID", "_NpcId", "_NPCID", "_NPCId" }) do
        local ok, value = safe_field(character, field_name)
        if ok and value ~= nil then
            table.insert(values, tostring(value))
        end
    end
    for _, method_name in ipairs({ "get_NpcID", "get_NpcId", "get_NPCID", "get_NPCId" }) do
        local ok, value = safe_call(character, method_name)
        if ok and value ~= nil then
            table.insert(values, tostring(value))
        end
    end
    for _, value in ipairs(values) do
        local npc_id = string.match(value, "NPC%d+_%d+_%d+")
        if npc_id then
            return npc_id
        end
    end
    return nil
end

local function same_runtime_object(a, b)
    if not a or not b then
        return false
    end
    if a == b then
        return true
    end
    return scene_object_key(a) == scene_object_key(b)
end

local function matches_player_instance(character, root_obj, player, label)
    if not player then
        return false, nil
    end
    if same_runtime_object(character, player) then
        return true, "character=" .. label
    end
    local ok_character, player_character = safe_call(player, "get_Character")
    if not ok_character or not player_character then
        return false, nil
    end
    if same_runtime_object(character, player_character) then
        return true, "character=" .. label .. ".get_Character"
    end
    local ok_object, player_root = safe_call(player_character, "get_Object")
    if not ok_object or not player_root then
        player_root = get_game_object(player_character)
    end
    if same_runtime_object(root_obj, player_root) then
        return true, "root=" .. label .. ".get_Character().get_Object"
    end
    return false, nil
end

-- 先排除玩家根对象，再按需核对原生玩家集合；不能假设联机玩家按固定顺序出现。
local function is_any_player_character(character, root_obj, check_player_manager)
    local root_name = get_game_object_name(root_obj)
    local lower_root_name = string.lower(tostring(root_name or ""))
    if lower_root_name == "masterplayer" then
        return true, "root_name=MasterPlayer"
    end
    if string.match(lower_root_name, "^player_replica_") then
        return true, "root_name=" .. tostring(root_name)
    end
    if check_player_manager == false or not sdk or type(sdk.get_managed_singleton) ~= "function" then
        return false, nil
    end
    local ok_manager, manager = pcall(sdk.get_managed_singleton, "app.PlayerManager")
    if not ok_manager or not manager then
        return false, nil
    end

    local ok_master, master = safe_call(manager, "getMasterPlayer")
    if ok_master and master then
        local matched, reason = matches_player_instance(character, root_obj, master, "PlayerManager.getMasterPlayer")
        if matched then
            return true, reason
        end
    end

    local ok_count, raw_count = safe_call(manager, "get_InstancedPlayerNum")
    local count = ok_count and tonumber(raw_count) or 0
    if count then
        count = math.max(0, math.min(math.floor(count), 16))
        for index = 0, count - 1 do
            local ok_player, player = safe_call(manager, "get_InstancedPlayer", index)
            if ok_player and player then
                local label = "PlayerManager.get_InstancedPlayer(" .. tostring(index) .. ")"
                local matched, reason = matches_player_instance(character, root_obj, player, label)
                if matched then
                    return true, reason
                end
            end
        end
    end
    return false, nil
end

local function reject_normal_player_character(character, root_obj, entry, reason)
    local key = tostring(character or "")
    if key ~= "" and not normal_player_rejections[key] then
        normal_player_rejections[key] = true
        performance.player_character_rejections = performance.player_character_rejections + 1
        record_event(
            "player_character_rejected",
            tostring(reason or "player identity")
                .. "; root=" .. tostring(get_game_object_name(root_obj))
                .. "; character=" .. key
        )
    end
    if entry then
        entry.player_character_rejected = true
        entry.match_status = "player_character_rejected"
    end
end
