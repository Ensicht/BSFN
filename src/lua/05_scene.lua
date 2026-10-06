-- =============================================================================
-- 场景代际与过渡隔离
-- =============================================================================
-- 加载前回调只设置状态；引用隔离、释放和诊断延后到原有 UpdateMotion。

local function scene_object_key(obj)
    if not obj then
        return nil
    end
    local ok, address = pcall(function()
        return obj:get_address()
    end)
    if ok and address then
        return tostring(address)
    end
    return tostring(obj)
end

-- 先移出可执行集合，再隔离引用；加载回调中不能集中销毁旧托管包装对象。
scene_transition.detach_cache = function(reason)
    local registered_count = 0
    for _ in pairs(registered) do
        registered_count = registered_count + 1
    end
    scene_transition.retired_registered[#scene_transition.retired_registered + 1] = registered
    if normal_runtime_gui_manager then
        scene_transition.retired_gui_managers[#scene_transition.retired_gui_managers + 1] = normal_runtime_gui_manager
    end
    registered = {}
    session_unmatched_cache = {}
    normal_player_rejections = {}
    last_armor_variant_sync_time = 0
    normal_runtime_gui_manager = nil
    quest_menu_last_state = false
    performance.scene_cache_clears = performance.scene_cache_clears + 1
    performance.scene_quarantine_batches = performance.scene_quarantine_batches + 1
    performance.scene_quarantined_entries = performance.scene_quarantined_entries + registered_count
    scene_transition.quarantined_current_entries = scene_transition.quarantined_current_entries + registered_count
    diagnostics.scene_generation = scene_generation
    diagnostics.scene_change_reason = tostring(reason or "scene_change")
    diagnostics.scene_transition.active = true
    diagnostics.scene_transition.status = "old cache detached; references quarantined until stable scene"
    diagnostics.scene_transition.end_seen = scene_transition.end_seen
    diagnostics.scene_transition.requires_fade_in = scene_transition.requires_fade_in
    diagnostics.scene_transition.stable_frames = scene_transition.stable_frames
    diagnostics.scene_transition.retired_batches = #scene_transition.retired_registered
    diagnostics.scene_transition.quarantined_entries = scene_transition.quarantined_current_entries
    record_event(
        "scene_cache_quarantined",
        "generation=" .. tostring(scene_generation)
            .. "; registered=" .. tostring(registered_count)
            .. "; reason=" .. tostring(reason or "scene_change")
    )
end

scene_transition.mark_start = function(reason, requires_fade_in)
    if config.scene_generation_enabled == false then
        return false
    end
    if scene_transition.active then
        return false
    end
    -- Keep this game-owned load-before callback allocation-free and free of managed-wrapper
    -- destruction. Cache detachment and all diagnostics run later from UpdateMotion.
    scene_transition.previous_key = scene_context_key
    scene_generation = scene_generation + 1
    scene_context_initialized = false
    scene_context_key = nil
    scene_transition.active = true
    scene_transition.pending_quarantine = true
    scene_transition.end_seen = false
    scene_transition.requires_fade_in = requires_fade_in == true
    scene_transition.start_reason = reason or "scene_load_before"
    scene_transition.end_reason = ""
    scene_transition.candidate_key = nil
    scene_transition.stable_frames = 0
    scene_transition.saw_loading = false
    performance.scene_changes = performance.scene_changes + 1
    performance.scene_transition_starts = performance.scene_transition_starts + 1
    diagnostics.scene_generation = scene_generation
    diagnostics.scene_change_reason = scene_transition.start_reason
    diagnostics.scene_transition.requires_fade_in = scene_transition.requires_fade_in
    return true
end

-- 黑屏旅行必须等对应淡入结束，普通 load-end 不能提前解除该门禁。
scene_transition.mark_end = function(reason, is_fade_in)
    if scene_transition.active then
        if scene_transition.requires_fade_in and is_fade_in ~= true then
            return false
        end
        scene_transition.end_seen = true
        scene_transition.end_reason = reason or "scene_load_end"
        performance.scene_transition_end_signals = performance.scene_transition_end_signals + 1
        return true
    end
    return false
end

local function read_scene_context_key()
    if not sdk then
        return nil
    end
    if not scene_manager_type then
        local ok_type, td = pcall(sdk.find_type_definition, "via.SceneManager")
        if ok_type and td then
            scene_manager_type = td
        end
    end
    if not scene_manager_type then
        return nil
    end
    local ok_manager, manager = pcall(sdk.get_native_singleton, "via.SceneManager")
    if not ok_manager or not manager then
        return nil
    end
    local scene = nil
    local main_view = nil
    pcall(function()
        scene = sdk.call_native_func(manager, scene_manager_type, "get_CurrentScene")
    end)
    pcall(function()
        main_view = sdk.call_native_func(manager, scene_manager_type, "get_MainView")
    end)
    local scene_key = scene_object_key(scene)
    local view_key = scene_object_key(main_view)
    if not scene_key and not view_key then
        return nil
    end
    return tostring(scene_key or "<nil>") .. "|" .. tostring(view_key or "<nil>")
end

scene_transition.initialize_context = function()
    if scene_transition.active or scene_context_initialized then
        return
    end
    local current_key = read_scene_context_key()
    if not current_key then
        return
    end
    scene_context_initialized = true
    scene_context_key = current_key
    diagnostics.scene_context_key = current_key
    diagnostics.scene_generation = scene_generation
end

scene_transition.read_loading = function()
    if not scene_transition.game_flow_probe_attempted then
        scene_transition.game_flow_probe_attempted = true
        local ok_type, td = pcall(sdk.find_type_definition, "app.GameFlowManager")
        if ok_type and td then
            pcall(function()
                scene_transition.game_flow_get_loading = td:get_method("get_Loading") or td:get_method("get_Loading()")
            end)
        end
    end
    if not scene_transition.game_flow_get_loading then
        return nil
    end
    local ok_manager, manager = pcall(sdk.get_managed_singleton, "app.GameFlowManager")
    if not ok_manager or not manager then
        return nil
    end
    local ok_loading, loading = pcall(function()
        return scene_transition.game_flow_get_loading:call(manager)
    end)
    if not ok_loading then
        return nil
    end
    return loading == true
end

scene_transition.release = function(current_key)
    local retired_batches = #scene_transition.retired_registered
    scene_transition.retired_registered = {}
    scene_transition.retired_gui_managers = {}
    scene_transition.quarantined_current_entries = 0
    performance.scene_quarantine_releases = performance.scene_quarantine_releases + 1
    performance.scene_transition_resumes = performance.scene_transition_resumes + 1
    scene_transition.active = false
    scene_transition.pending_quarantine = false
    scene_transition.requires_fade_in = false
    scene_transition.candidate_key = nil
    scene_transition.stable_frames = 0
    scene_context_initialized = true
    scene_context_key = current_key
    diagnostics.scene_context_key = tostring(current_key or "")
    diagnostics.scene_transition.active = false
    diagnostics.scene_transition.status = "stable scene confirmed; quarantined references released"
    diagnostics.scene_transition.end_seen = scene_transition.end_seen
    diagnostics.scene_transition.requires_fade_in = false
    diagnostics.scene_transition.stable_frames = scene_transition.resume_stable_frames
    diagnostics.scene_transition.retired_batches = 0
    diagnostics.scene_transition.quarantined_entries = 0
    record_event(
        "scene_cache_released",
        "generation=" .. tostring(scene_generation)
            .. "; retired_batches=" .. tostring(retired_batches)
            .. "; end=" .. tostring(scene_transition.end_reason)
            .. "; key=" .. tostring(current_key or "")
    )
end

-- 只在过渡期读取 Loading；原生结束证据和有效场景身份满足后，同帧恢复普通处理。
scene_transition.update = function()
    if not scene_transition.active then
        return false
    end
    if scene_transition.pending_quarantine then
        scene_transition.pending_quarantine = false
        scene_transition.detach_cache(scene_transition.start_reason)
    end
    performance.scene_transition_resume_checks = performance.scene_transition_resume_checks + 1
    local loading = scene_transition.read_loading()
    if loading == true then
        scene_transition.saw_loading = true
        scene_transition.candidate_key = nil
        scene_transition.stable_frames = 0
        diagnostics.scene_transition.status = "waiting for game loading to end"
        diagnostics.scene_transition.end_seen = scene_transition.end_seen
        diagnostics.scene_transition.stable_frames = 0
        return true
    end
    local current_key = read_scene_context_key()
    if not current_key then
        scene_transition.candidate_key = nil
        scene_transition.stable_frames = 0
        diagnostics.scene_transition.status = "waiting for a live SceneManager identity"
        diagnostics.scene_transition.end_seen = scene_transition.end_seen
        diagnostics.scene_transition.stable_frames = 0
        return true
    end
    local lifecycle_ready = scene_transition.requires_fade_in
        and scene_transition.end_seen
        or (scene_transition.requires_fade_in == false and (
            scene_transition.end_seen
            or (scene_transition.saw_loading and loading == false)
            or (scene_transition.previous_key and current_key ~= scene_transition.previous_key)
        ))
    if not lifecycle_ready then
        scene_transition.candidate_key = nil
        scene_transition.stable_frames = 0
        diagnostics.scene_transition.status = scene_transition.requires_fade_in
            and "waiting for black-screen scene fade-in"
            or "waiting for load-end or changed scene identity"
        diagnostics.scene_transition.end_seen = false
        diagnostics.scene_transition.requires_fade_in = scene_transition.requires_fade_in
        diagnostics.scene_transition.stable_frames = 0
        return true
    end
    if current_key == scene_transition.candidate_key then
        scene_transition.stable_frames = scene_transition.stable_frames + 1
    else
        scene_transition.candidate_key = current_key
        scene_transition.stable_frames = 1
    end
    diagnostics.scene_transition.status = "new scene identity stabilizing"
    diagnostics.scene_transition.end_seen = scene_transition.end_seen
    diagnostics.scene_transition.stable_frames = scene_transition.stable_frames
    if scene_transition.stable_frames < scene_transition.resume_stable_frames then
        return true
    end
    scene_transition.release(current_key)
    return false
end

-- 生命周期 Hook 不可用时才采用一秒一次的场景身份回退，不与 Hook 路径叠加。
local function update_scene_generation_fallback()
    if config.scene_generation_enabled == false then
        return
    end
    if scene_transition_hook_installed then
        return
    end
    local now = os.clock()
    if now < next_scene_fallback_poll then
        return
    end
    next_scene_fallback_poll = now + SCENE_FALLBACK_POLL_INTERVAL
    performance.scene_fallback_polls = performance.scene_fallback_polls + 1
    local current_key = read_scene_context_key()
    if not current_key then
        return
    end
    if not scene_context_initialized then
        scene_context_initialized = true
        scene_context_key = current_key
        diagnostics.scene_context_key = current_key
        diagnostics.scene_generation = scene_generation
        return
    end
    if current_key ~= scene_context_key then
        scene_transition.mark_start("scene_context_changed")
        scene_transition.mark_end("SceneManager identity changed")
    end
end
