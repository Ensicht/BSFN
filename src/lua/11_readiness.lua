 
 
 
 

local function get_component(game_obj, type_name)
    local rt = get_runtime_type(type_name)
    if not rt then
        return nil
    end
    local ok, component = safe_call(game_obj, "getComponent(System.Type)", rt)
    if ok and component then
        return component
    end
    ok, component = pcall(function()
        return game_obj:getComponent(rt)
    end)
    if ok and component then
        return component
    end
    return nil
end

local function inspect_candidate(game_obj, label)
    local motion = get_component(game_obj, "via.motion.Motion")
    local custom = get_component(game_obj, "via.motion.CustomSkeleton")
    local ready = motion ~= nil and custom ~= nil
    if ready then
        stats.candidates_ready = stats.candidates_ready + 1
    end
    return {
        label = label,
        object = tostring(game_obj),
        name = get_game_object_name(game_obj),
        has_motion = motion ~= nil,
        has_custom_skeleton = custom ~= nil,
        ready_for_stage = ready
    }, motion, custom
end

local function build_candidates(root_obj, body_id, extra_roots)
    local result = {}
    local seen = {}
    local function add(game_obj, label)
        if not game_obj then
            return
        end
        local key = tostring(game_obj)
        if seen[key] then
            return
        end
        seen[key] = true
        table.insert(result, { obj = game_obj, label = label, name = get_game_object_name(game_obj) })
    end
    add(root_obj, "root")
    local scan_roots = collect_scan_roots(root_obj, extra_roots)
    for _, scan_root in ipairs(scan_roots) do
        if scan_root ~= root_obj then
            add(scan_root, "event_model_target")
        end
    end
    local children = {}
    local child_seen = {}
    for _, scan_root in ipairs(scan_roots) do
        for _, obj in ipairs(collect_child_game_objects(scan_root)) do
            local key = tostring(obj)
            if not child_seen[key] then
                child_seen[key] = true
                table.insert(children, obj)
            end
        end
    end
    for _, obj in ipairs(children) do
        local name = get_game_object_name(obj)
        if body_id and lower_contains(name, body_id) then
            add(obj, "body_match")
        elseif string.find(name, "^ch0[23]_") then
            add(obj, "armor_child")
        end
    end
    for _, obj in ipairs(children) do
        add(obj, "child")
    end
    return result
end

local function load_bone_config(body_id)
    if not body_id or body_id == "" then
        return nil, "empty body id"
    end
    if bone_config_cache[body_id] then
        return bone_config_cache[body_id], "cache"
    end
    local path = "BoneSystem/" .. tostring(body_id) .. ".json"
    local ok, data = pcall(function()
        return json.load_file(path)
    end)
    if ok and type(data) == "table" then
        bone_config_cache[body_id] = data
        return data, path
    end
    return nil, "failed to load " .. path .. ": " .. tostring(data)
end

local function parse_pointer_text(obj)
    local text = tostring(obj or "")
    local hex = string.match(text, "0x([0-9a-fA-F]+)") or string.match(text, ":%s*([0-9a-fA-F]+)") or string.match(text, "([0-9a-fA-F]+)$")
    if hex then
        local value = tonumber(hex, 16)
        if value then
            return "0x" .. hex, value
        end
    end
    return "", nil
end

local function get_address_text(obj)
    local ok, addr = call_any(obj, "get_address")
    if ok and addr then
        return tostring(addr), addr
    end
    return parse_pointer_text(obj)
end

local function resource_path_from_bone_data(bone_data)
    if type(bone_data) ~= "table" then
        return nil
    end
    local fbx_path = bone_data.FbxPath
    if type(fbx_path) ~= "string" or fbx_path == "" then
        return nil
    end
     
    return string.format("BoneSystem/%s.fbxskel", fbx_path)
end

local function clear_entry_readiness(entry, status, clear_pending)
    if not entry then
        return
    end
    if entry.readiness_signature or (entry.readiness_stable_frames or 0) > 0 then
        performance.readiness_resets = performance.readiness_resets + 1
    end
    entry.readiness_signature = nil
    entry.readiness_stable_frames = 0
    entry.readiness_burst_checks = 0
    entry.readiness_holder_address = nil
    entry.readiness_status = tostring(status or "reset")
    if clear_pending then
        entry.next_readiness_probe = nil
        entry.pending_key = nil
        entry.pending_target = nil
        entry.pending_body_id = nil
        entry.pending_bone_body_id = nil
        entry.pending_match_source = nil
        entry.pending_dictionary_generation = nil
    end
end

local function begin_entry_readiness(entry, resolution)
    if not entry or not resolution or not resolution.target then
        return false
    end
    local target = resolution.target
    local body_id = resolution.body_id or target.body_id
    local bone_body_id = target.bone_system_body_id or body_id or target.body_id
    local bone_data, bone_source = load_bone_config(bone_body_id)
    if type(bone_data) ~= "table" then
        clear_entry_readiness(entry, "bone config unavailable: " .. tostring(bone_source), true)
        return false
    end
    local pending_key = table.concat({
        tostring(target.npc_id or target.display_name or "target"),
        tostring(body_id or ""),
        tostring(bone_body_id or ""),
        tostring(dictionary_generation),
        tostring(scene_generation)
    }, "|")
    if entry.pending_key ~= pending_key then
        clear_entry_readiness(entry, "new pending target", false)
    end
    entry.pending_key = pending_key
    entry.pending_target = target
    entry.pending_body_id = body_id
    entry.pending_bone_body_id = bone_body_id
    entry.pending_match_source = resolution.match_source
    entry.pending_dictionary_generation = dictionary_generation
    entry.next_readiness_probe = nil
    entry.readiness_status = "waiting for constructed skeleton"
    return true
end

 
local function probe_candidate_bone_state(game_obj, label)
    if not game_obj then
        return nil, "nil candidate"
    end
    local motion = get_component(game_obj, "via.motion.Motion")
    local custom_skeleton = get_component(game_obj, "via.motion.CustomSkeleton")
    if not motion or not custom_skeleton then
        return nil, "missing Motion or CustomSkeleton"
    end
    local joints_ok, joints_constructed = call_any(motion, "get_JointsConstructed")
    if not joints_ok or joints_constructed ~= true then
        return nil, "joints not constructed"
    end
    local holder_ok, holder = call_any(custom_skeleton, "get_SkeletonResourceHandle")
    if not holder_ok or not holder then
        return nil, "missing SkeletonResourceHandle"
    end
    local path_ok, resource_path = call_any(holder, "get_ResourcePath")
    resource_path = path_ok and tostring(resource_path or "") or ""
    if resource_path == "" then
        return nil, "unreadable SkeletonResourceHandle path"
    end
    local game_object_address = select(1, get_address_text(game_obj))
    local motion_address = select(1, get_address_text(motion))
    local custom_skeleton_address = select(1, get_address_text(custom_skeleton))
    local holder_address = select(1, get_address_text(holder))
    if game_object_address == "" or motion_address == "" or custom_skeleton_address == "" then
        return nil, "missing runtime address"
    end
    local candidate_name = get_game_object_name(game_obj)
    local signature = table.concat({
        tostring(scene_generation),
        tostring(game_object_address),
        tostring(motion_address),
        tostring(custom_skeleton_address),
        tostring(candidate_name),
        tostring(resource_path)
    }, "|")
    return {
        signature = signature,
        scene_generation = scene_generation,
        candidate = game_obj,
        candidate_label = tostring(label or "candidate"),
        candidate_name = candidate_name,
        motion = motion,
        custom_skeleton = custom_skeleton,
        holder = holder,
        resource_path = resource_path,
        joints_constructed = true,
        game_object_address = game_object_address,
        motion_address = motion_address,
        custom_skeleton_address = custom_skeleton_address,
        holder_address = holder_address
    }
end

local function find_current_ready_bone_state(entry)
    if not entry or not entry.character or not entry.pending_target then
        return nil, "no pending target"
    end
    local root_obj = get_game_object(entry.character)
    if not root_obj then
        return nil, "no current root GameObject"
    end
    local body_id = entry.pending_body_id or entry.pending_target.body_id
    local candidates = build_candidates(root_obj, body_id, nil)
    local first_reason = "no candidate"
    for _, candidate in ipairs(candidates) do
        local state, reason = probe_candidate_bone_state(candidate.obj, candidate.label)
        if state then
            state.root_obj = root_obj
            return state
        end
        if first_reason == "no candidate" and reason then
            first_reason = tostring(reason)
        end
    end
    return nil, first_reason
end

 
local function update_entry_readiness(entry, now)
    if entry.scene_generation ~= scene_generation then
        clear_entry_readiness(entry, "scene generation changed", true)
        return nil, "scene generation changed"
    end
    if entry.pending_dictionary_generation ~= dictionary_generation then
        clear_entry_readiness(entry, "dictionary generation changed", true)
        return nil, "dictionary generation changed"
    end
    local recent_window = tonumber(config.readiness_recent_seen_window) or 0.5
    if recent_window < 0.1 then
        recent_window = 0.1
    end
    if now - entry.last_seen > recent_window then
        clear_entry_readiness(entry, "NpcCharacter update not recent", false)
        entry.next_readiness_probe = now + (tonumber(config.readiness_retry_interval) or 0.1)
        performance.readiness_waits = performance.readiness_waits + 1
        return nil, entry.readiness_status
    end
    local retry_interval = tonumber(config.readiness_retry_interval) or 0.1
    if retry_interval < 0.1 then
        retry_interval = 0.1
    end
    if not entry.readiness_signature and entry.next_readiness_probe and now < entry.next_readiness_probe then
        performance.readiness_throttled = performance.readiness_throttled + 1
        return nil, entry.readiness_status
    end
    performance.readiness_checks = performance.readiness_checks + 1
    local state, reason = find_current_ready_bone_state(entry)
    if not state then
        clear_entry_readiness(entry, reason or "not ready", false)
        entry.next_readiness_probe = now + retry_interval
        performance.readiness_waits = performance.readiness_waits + 1
        return nil, entry.readiness_status
    end
    entry.next_readiness_probe = nil
    if entry.readiness_holder_address and state.holder_address
        and entry.readiness_holder_address ~= state.holder_address then
        performance.readiness_holder_identity_changes = performance.readiness_holder_identity_changes + 1
    end
    entry.readiness_holder_address = state.holder_address
    entry.readiness_burst_checks = (entry.readiness_burst_checks or 0) + 1
    local max_burst_checks = math.floor(tonumber(config.readiness_max_burst_checks) or 12)
    if max_burst_checks < 3 then
        max_burst_checks = 3
    end
    if entry.readiness_burst_checks > max_burst_checks then
        clear_entry_readiness(entry, "unstable readiness burst; retry throttled", false)
        entry.next_readiness_probe = now + retry_interval
        performance.readiness_throttled = performance.readiness_throttled + 1
        return nil, entry.readiness_status
    end
    if entry.readiness_signature == state.signature then
        entry.readiness_stable_frames = (entry.readiness_stable_frames or 0) + 1
    else
        if entry.readiness_signature then
            performance.readiness_resets = performance.readiness_resets + 1
        end
        entry.readiness_signature = state.signature
        entry.readiness_stable_frames = 1
    end
    local required_frames = math.floor(tonumber(config.readiness_stable_frames) or 1)
    if required_frames < 1 then
        required_frames = 1
    end
    if required_frames == 1 then
        entry.readiness_status = "ready in current frame"
    else
        entry.readiness_status = "stable " .. tostring(entry.readiness_stable_frames) .. "/" .. tostring(required_frames)
    end
    if entry.readiness_stable_frames < required_frames then
        performance.readiness_waits = performance.readiness_waits + 1
        return nil, entry.readiness_status
    end
    performance.readiness_stable = performance.readiness_stable + 1
    return state, entry.readiness_status
end
