-- =============================================================================
-- 目标解析与未命中缓存
-- =============================================================================
-- 保留显式目标优先级；自动候选按身体编号查字典，不逐套装匹配。

-- 男女猎人装备使用同一字典；原生脸、NPC本体和其他模型前缀不参与自动匹配。
local function body_id_from_object_name(name)
    return string.match(tostring(name or ""), "(ch0[23]_%d%d%d_%d%d%d%d)")
end

local function resolve_named_part_object(part)
    if not part then
        return nil, ""
    end
    local direct_name = get_game_object_name(part)
    if direct_name ~= "" then
        return part, direct_name
    end
    local game_obj = get_game_object(part)
    if not game_obj then
        return part, ""
    end
    return game_obj, get_game_object_name(game_obj)
end

local function read_chest_state(character)
    performance.chest_reads = performance.chest_reads + 1
    local state = {
        chest_object = nil,
        chest_name = "",
        chest_body_id = nil,
        source = "direct_chest",
        cache_route = "direct"
    }
    local ok_part, part = safe_call(character, "getParts", 1)
    if not ok_part or not part then
        return state
    end
    state.chest_object, state.chest_name = resolve_named_part_object(part)
    state.chest_body_id = body_id_from_object_name(state.chest_name)
    return state
end

local function clear_fallback_cache(entry)
    entry.fallback_object = nil
    entry.fallback_name = ""
    entry.fallback_body_id = nil
    entry.fallback_source = nil
end

local function read_cached_fallback(entry, expected_body_id)
    if entry.dictionary_generation ~= dictionary_generation
        or not entry.fallback_object
        or not is_valid_managed_object(entry.fallback_object) then
        return nil
    end
    local current_name = get_game_object_name(entry.fallback_object)
    if current_name == "" or current_name ~= entry.fallback_name then
        clear_fallback_cache(entry)
        return nil
    end
    local body_id = body_id_from_object_name(current_name) or entry.fallback_body_id
    if expected_body_id then
        if body_id ~= expected_body_id then
            return nil
        end
    elseif not auto_by_body_id[body_id] then
        return nil
    end
    performance.fallback_cache_hits = performance.fallback_cache_hits + 1
    return {
        chest_object = entry.fallback_object,
        chest_name = current_name,
        chest_body_id = body_id,
        source = "fallback_cache",
        cache_route = "fallback"
    }
end

local function collect_scan_roots(root_obj, extra_roots)
    local roots = {}
    local seen = {}
    local function add(obj)
        if not obj then
            return
        end
        local key = tostring(obj)
        if seen[key] then
            return
        end
        seen[key] = true
        table.insert(roots, obj)
    end
    add(root_obj)
    for _, obj in ipairs(extra_roots or {}) do
        add(obj)
    end
    return roots
end

-- 直接 Chest 不可用时才遍历有限子树，已找到的载体按对象身份复用。
local function scan_fallback_outfit(root_obj, expected_body_id, entry, extra_roots)
    performance.fallback_scans = performance.fallback_scans + 1
    local scanned = {}
    for _, scan_root in ipairs(collect_scan_roots(root_obj, extra_roots)) do
        for _, obj in ipairs(collect_child_game_objects(scan_root)) do
            local key = tostring(obj)
            if not scanned[key] then
                scanned[key] = true
                local name = get_game_object_name(obj)
                for body_id in string.gmatch(name, "(ch0[23]_%d%d%d_%d%d%d%d)") do
                    local matched = expected_body_id and body_id == expected_body_id
                        or (not expected_body_id and auto_by_body_id[body_id] ~= nil)
                    if matched then
                        entry.fallback_object = obj
                        entry.fallback_name = name
                        entry.fallback_body_id = body_id
                        entry.fallback_source = expected_body_id and "manual" or "auto"
                        return {
                            chest_object = obj,
                            chest_name = name,
                            chest_body_id = body_id,
                            source = scan_root == root_obj and "fallback_child" or "event_model_target",
                            cache_route = "fallback"
                        }
                    end
                end
            end
        end
    end
    clear_fallback_cache(entry)
    return nil
end

local function update_resolution_cache(entry, npc_id, outfit_state)
    outfit_state = outfit_state or {
        chest_object = nil,
        chest_name = "",
        chest_body_id = nil,
        source = "none",
        cache_route = "none"
    }
    local cache_changed = entry.dictionary_generation ~= dictionary_generation
        or entry.npc_id ~= npc_id
        or entry.chest_object ~= outfit_state.chest_object
        or entry.chest_name ~= outfit_state.chest_name
        or entry.chest_body_id ~= outfit_state.chest_body_id
        or entry.outfit_source ~= outfit_state.cache_route
    if cache_changed then
        entry.applied = false
        entry.target = nil
        entry.body_id = nil
        entry.bone_body_id = nil
        entry.resolved_target = nil
        entry.pending_target = nil
        entry.pending_body_id = nil
        entry.pending_bone_body_id = nil
        entry.pending_match_source = nil
        entry.pending_dictionary_generation = nil
        entry.pending_key = nil
        entry.readiness_signature = nil
        entry.readiness_stable_frames = 0
        entry.readiness_burst_checks = 0
        entry.readiness_holder_address = nil
        entry.next_readiness_probe = nil
        entry.readiness_status = "resolution cache changed"
        entry.session_unmatched_key = nil
        entry.session_unmatched_generation = nil
        entry.unmatched_attempts = 0
    end
    entry.npc_id = npc_id
    entry.chest_object = outfit_state.chest_object
    entry.chest_name = outfit_state.chest_name
    entry.chest_body_id = outfit_state.chest_body_id
    entry.outfit_source = outfit_state.cache_route
    entry.dictionary_generation = dictionary_generation
    return cache_changed
end

local function remember_unmatched(npc_id, chest_state, status)
    local entry = {
        time = os.clock(),
        npc_id = tostring(npc_id or ""),
        chest_name = trim_text(chest_state and chest_state.chest_name or "", 180),
        chest_body_id = tostring(chest_state and chest_state.chest_body_id or ""),
        source = tostring(chest_state and chest_state.source or ""),
        status = tostring(status or "unmatched")
    }
    local last = diagnostics.recent_unmatched[#diagnostics.recent_unmatched]
    if last and last.npc_id == entry.npc_id and last.chest_name == entry.chest_name and last.status == entry.status then
        last.time = entry.time
        return
    end
    table.insert(diagnostics.recent_unmatched, entry)
    while #diagnostics.recent_unmatched > 16 do
        table.remove(diagnostics.recent_unmatched, 1)
    end
end

local function npc_is_auto_blocked(npc_id)
    if not npc_id or type(config.auto_target_npc_blocklist) ~= "table" then
        return false
    end
    for _, blocked in ipairs(config.auto_target_npc_blocklist) do
        if tostring(blocked) == npc_id then
            return true
        end
    end
    return false
end

-- 空 Chest 的未命中键包含根对象，避免艺术馆中的空模型污染正常场景的同名 NPC。
local function make_session_unmatched_key(npc_id, chest_state, root_obj, allow_empty)
    chest_state = chest_state or {}
    local identity = tostring(npc_id or "")
    if identity == "" then
        identity = tostring(root_obj or "")
    end
    if identity == "" then
        return nil
    end
    local chest_body_id = tostring(chest_state.chest_body_id or "")
    local chest_name = tostring(chest_state.chest_name or "")
    if chest_body_id == "" and chest_name == "" then
        if not allow_empty then
            return nil
        end
        chest_name = "<not_loaded>"
        -- An empty Chest is a loading state; keep its miss local to this model object.
        local root_identity = tostring(root_obj or "")
        if root_identity ~= "" and root_identity ~= identity then
            identity = identity .. "@" .. root_identity
        end
    end
    return table.concat({ tostring(dictionary_generation), identity, chest_body_id, chest_name }, "|")
end

-- 玩家隔离 -> 专属规则 -> 自动字典；未命中缓存和艺术馆隔离选项在同一处执行。
local function resolve_target(character, root_obj, entry, options)
    options = options or {}
    local npc_id = options.npc_id or read_npc_id(character, root_obj)
    local is_player, player_reason = is_any_player_character(character, root_obj, npc_id == nil)
    if is_player then
        reject_normal_player_character(character, root_obj, entry, player_reason)
        return nil, "player_character_rejected"
    end
    performance.match_attempts = performance.match_attempts + 1
    local manual_target = npc_id and manual_by_npc_id[npc_id] or nil
    local chest_state = options.chest_state or read_chest_state(character)
    local extra_roots = options.extra_roots

    if manual_target then
        local expected_body_id = manual_target.body_id and tostring(manual_target.body_id) or nil
        local matched_state = nil
        if manual_target.require_body_id == false then
            matched_state = chest_state
        elseif expected_body_id and chest_state.chest_body_id == expected_body_id then
            clear_fallback_cache(entry)
            matched_state = chest_state
        else
            matched_state = read_cached_fallback(entry, expected_body_id)
                or scan_fallback_outfit(root_obj, expected_body_id, entry, extra_roots)
            if matched_state then
                performance.manual_fallback_hits = performance.manual_fallback_hits + 1
            end
        end
        if matched_state then
            local cache_changed = update_resolution_cache(entry, npc_id, matched_state)
            performance.manual_hits = performance.manual_hits + 1
            entry.resolved_target = manual_target
            bs_log("[Match] source=manual npc_id=" .. tostring(npc_id)
                .. " body_id=" .. tostring(matched_state.chest_body_id or expected_body_id or "")
                .. " route=" .. tostring(matched_state.source))
            return {
                target = manual_target,
                body_id = matched_state.chest_body_id or expected_body_id,
                match_source = "manual_by_npc_id",
                npc_id = npc_id,
                chest_state = matched_state,
                cache_changed = cache_changed
            }
        end
        update_resolution_cache(entry, npc_id, chest_state)
        performance.manual_pending = performance.manual_pending + 1
        remember_unmatched(npc_id, chest_state, "manual_pending")
        bs_log("[Match] source=manual_pending npc_id=" .. tostring(npc_id)
            .. " expected=" .. tostring(expected_body_id or "")
            .. " actual=" .. tostring(chest_state.chest_body_id or ""))
        return nil, "manual_pending"
    end

    local existing_session_key = make_session_unmatched_key(npc_id, chest_state, root_obj, true)
    if options.disable_session_cache ~= true and existing_session_key and session_unmatched_cache[existing_session_key] then
        update_resolution_cache(entry, npc_id, chest_state)
        entry.session_unmatched_key = existing_session_key
        entry.session_unmatched_generation = dictionary_generation
        performance.session_unmatched_cache_hits = performance.session_unmatched_cache_hits + 1
        remember_unmatched(npc_id, chest_state, "unmatched_session_cache")
        return nil, "unmatched_session_cache"
    end

    local matched_state = chest_state
    local auto_target = nil
    if not npc_is_auto_blocked(npc_id) then
        if chest_state.chest_body_id then
            auto_target = auto_by_body_id[chest_state.chest_body_id]
        end
        if auto_target then
            clear_fallback_cache(entry)
        else
            matched_state = read_cached_fallback(entry, nil)
                or scan_fallback_outfit(root_obj, nil, entry, extra_roots)
            if matched_state then
                auto_target = auto_by_body_id[matched_state.chest_body_id]
                if auto_target then
                    performance.auto_fallback_hits = performance.auto_fallback_hits + 1
                end
            end
        end
    end

    local effective_state = matched_state or chest_state
    local cache_changed = update_resolution_cache(entry, npc_id, effective_state)
    if auto_target then
        performance.auto_hits = performance.auto_hits + 1
        entry.resolved_target = auto_target
        bs_log("[Match] source=auto body_id=" .. tostring(matched_state.chest_body_id)
            .. " route=" .. tostring(matched_state.source))
        return {
            target = auto_target,
            body_id = matched_state.chest_body_id,
            match_source = "auto_by_body_id",
            npc_id = npc_id,
            chest_state = matched_state,
            cache_changed = cache_changed
        }
    end

    performance.unmatched = performance.unmatched + 1
    entry.unmatched_attempts = (entry.unmatched_attempts or 0) + 1
    if options.disable_session_cache == true then
        remember_unmatched(npc_id, effective_state, "event_model_unmatched")
        return nil, "event_model_unmatched"
    end
    local allow_empty = entry.unmatched_attempts >= 3
    local session_key = make_session_unmatched_key(npc_id, chest_state, root_obj, allow_empty)
    if session_key then
        session_unmatched_cache[session_key] = true
        entry.session_unmatched_key = session_key
        entry.session_unmatched_generation = dictionary_generation
        performance.session_unmatched_cached = performance.session_unmatched_cached + 1
        remember_unmatched(npc_id, effective_state, "unmatched_session_cached")
        return nil, "unmatched_session_cached"
    end
    performance.unmatched_load_retries = performance.unmatched_load_retries + 1
    remember_unmatched(npc_id, effective_state, "unmatched_loading_retry")
    return nil, "unmatched_loading_retry"
end
