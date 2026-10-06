 
 

 
 
 
 

local API = rawget(_G, "BoneSystemNPCAPI")
if type(API) ~= "table" or not rawget(_G, "__BSFNStockBridgeAuthorized") then
    if not rawget(_G, "__BSFNStockBridgeMainStarted") then
        _G.__BSFNStockBridgeMainStarted = true
        local loader, load_error = package.loadlib("reframework/plugins/BSFNStockBridge.dll", "bsfn_bootstrap")
        if loader then
            local ok, err = pcall(loader)
            if not ok then log.error("[BSFNStockBridge] " .. tostring(err)) end
        else
            log.error("[BSFNStockBridge] " .. tostring(load_error))
        end
    end
    return
end
if rawget(_G, "__BoneSystemForNPCLoaded") or rawget(_G, "__BoneSystemForNPCStagedLoaded") then
    return
end
_G.__BoneSystemForNPCLoaded = true
_G.__BoneSystemForNPCStagedLoaded = true

 
 
 
 

local MOD_NAME = "BoneSystemForNPC"
local VERSION = "1.7.5"
local CONFIG_PATH = "BoneSystemForNPC/Config.json"
local TARGETS_DIR = "BoneSystemForNPC/Targets"
local TARGET_INDEX_PATH = "BoneSystemForNPC/TargetIndex.json"

local TARGETS_GLOB_PATTERNS = {
    "BoneSystemForNPC\\\\Targets\\\\.*\\.json",
    "BoneSystemForNPC/Targets/.*\\.json"
}
local BONE_SYSTEM_INDEX_PATH = "BoneSystemForNPC/BoneSystemIndex.json"
local DEFAULT_BONE_SYSTEM_SCAN_PATTERNS = {
    "BoneSystem\\\\.*\\.json",
    "BoneSystem/.*\\.json"
}
local REPORT_PATH = "BoneSystemForNPC/fornpc_report.json"
local unpack_args = table.unpack or unpack

local default_config = {
    language = "zh",
    enabled = true,
    ui_enabled = true,
    mode = "api_fix_bone",
    enable_native_fix = false,
    debug_log = false,
    write_report = false,
    report_interval = 1.0,
    inspect_interval = 1.0,
    apply_delay = 2.0,  
    readiness_stable_frames = 1,
    readiness_recent_seen_window = 0.5,
    readiness_retry_interval = 0.1,
    readiness_max_burst_checks = 12,
    scene_generation_enabled = true,
    apply_once = true,
    max_recursive_children = 128,
    auto_apply_bone = true,
    auto_apply_face_mapping = true,
    default_private_face_mode = false,
    auto_sync_armor_variant = true,
    use_armor_variant_manager_api = false,
    use_builtin_armor_variant_sync = true,
    armor_variant_mode = "static_defaults",
    armor_variant_trace_limit = 64,
    armor_variant_trace_materials = { "Face", "Eyes", "EyesHighLight", "EyesWhite", "Mouth", "Mouth_Card" },
    armor_variant_reapply_interval = 0.0,
    registered_entry_ttl = 3.0,
    armor_variant_recent_seen_window = 1.0,
    edit_region_trace = false,
    edit_region_trace_candidates = 8,
    bone_system_scan_patterns = DEFAULT_BONE_SYSTEM_SCAN_PATTERNS,
    use_bone_system_index = true,
    bone_system_index_path = BONE_SYSTEM_INDEX_PATH,
    auto_target_npc_blocklist = {},
    targets = {}
}

local config = default_config
local target_cache = nil
local loaded_target_paths = {}
local manual_by_npc_id = {}
local auto_by_body_id = {}
local dictionary_generation = 0
local type_cache = {}
local bone_config_cache = {}
local npc_id_by_value = nil
local registered = {}
local session_unmatched_cache = {}
local normal_player_rejections = {}
local retained_resources = {}
local scene_generation = 0
local scene_context_initialized = false
local scene_context_key = nil
local scene_manager_type = nil
local scene_transition_hook_installed = false
local scene_transition = {
    end_hook_count = 0,
    black_screen_start_hook_count = 0,
    fade_in_end_hook_count = 0,
    active = false,
    pending_quarantine = false,
    end_seen = false,
    requires_fade_in = false,
    start_reason = "startup",
    end_reason = "",
    previous_key = nil,
    candidate_key = nil,
    stable_frames = 0,
    saw_loading = false,
    retired_registered = {},
    retired_gui_managers = {},
    quarantined_current_entries = 0,
    game_flow_probe_attempted = false,
    game_flow_get_loading = nil,
    resume_stable_frames = 1
}
local next_scene_fallback_poll = 0.0
local SCENE_FALLBACK_POLL_INTERVAL = 1.0
local performance = {
    match_attempts = 0,
    chest_reads = 0,
    fallback_scans = 0,
    fallback_cache_hits = 0,
    manual_hits = 0,
    manual_pending = 0,
    manual_fallback_hits = 0,
    auto_hits = 0,
    auto_fallback_hits = 0,
    unmatched = 0,
    session_unmatched_cached = 0,
    session_unmatched_cache_hits = 0,
    unmatched_load_retries = 0,
    apply_once_fast_skips = 0,
    game_object_failures = 0,
    scene_changes = 0,
    scene_cache_clears = 0,
    scene_fallback_polls = 0,
    scene_transition_starts = 0,
    scene_transition_end_signals = 0,
    scene_transition_resume_checks = 0,
    scene_transition_resumes = 0,
    scene_quarantine_batches = 0,
    scene_quarantined_entries = 0,
    scene_quarantine_releases = 0,
    scene_registration_suppressed = 0,
    scene_event_model_suppressed = 0,
    player_character_rejections = 0,
    readiness_checks = 0,
    readiness_throttled = 0,
    readiness_waits = 0,
    readiness_stable = 0,
    readiness_resets = 0,
    readiness_holder_identity_changes = 0,
    readiness_final_mismatches = 0,
    event_model_hook_hits = 0,
    event_model_completed_hits = 0,
    event_model_incomplete_skips = 0,
    event_model_apply_attempts = 0,
    event_model_apply_ok = 0,
    event_model_variant_ok = 0,
    event_model_unmatched = 0,
    event_model_errors = 0
}
local diagnostics = {
    events = {},
    inspections = {},
    operations = {},
    target_files = {},
    bone_system_scan = {},
    manual_targets = {},
    auto_targets = {},
    collisions = {},
    recent_unmatched = {},
    armor_variant = {},
    event_model_setups = {},
    bone_scan_status = "not_run",
    bone_index_status = "not_run",
    target_scan_status = "not_run",
    target_index_status = "not_run",
    auto_dictionary_source = "none",
    manual_dictionary_source = "none",
    scene_generation = 0,
    scene_context_key = "",
    scene_change_reason = "startup",
    scene_transition = {
        active = false,
        status = "startup",
        end_seen = false,
        requires_fade_in = false,
        stable_frames = 0,
        retired_batches = 0,
        quarantined_entries = 0
    },
    last_report_time = 0
}
local hook_state = {
    npc = "not attempted",
    event_model_npc = "not attempted",
    scene = "not attempted",
    update = "not attempted"
}
local normal_runtime_menu_suspended = false
local normal_runtime_pause_started = nil
local normal_runtime_paused_time = 0
local normal_runtime_gui_manager = nil

 
 
 
 

 
local function normal_runtime_clock()
    local now = os.clock()
    local active_pause = normal_runtime_pause_started and (now - normal_runtime_pause_started) or 0
    return now - normal_runtime_paused_time - active_pause
end
local quest_menu_id = nil
local quest_menu_last_state = false

local function resolve_quest_menu_id()
    if quest_menu_id ~= nil then return quest_menu_id end
    local type_def = sdk.find_type_definition("app.GUIID.ID")
    if type_def == nil then return nil end
    local ok, field = pcall(function() return type_def:get_field("UI050000") end)
    if not ok or field == nil then return nil end
    pcall(function() quest_menu_id = field:get_data() end)
    return quest_menu_id
end

 
local function read_quest_fullscreen_open()
    local menu_id = resolve_quest_menu_id()
    if menu_id == nil then return false end
    if normal_runtime_gui_manager == nil then
        normal_runtime_gui_manager = sdk.get_managed_singleton("app.GUIManager")
    end
    if normal_runtime_gui_manager == nil then return quest_menu_last_state end

    local gui_ok, gui = pcall(function()
        return normal_runtime_gui_manager:call("getGUI(app.GUIID.ID)", menu_id)
    end)
    if not gui_ok then
        normal_runtime_gui_manager = nil
        return quest_menu_last_state
    end
    if gui == nil then
        quest_menu_last_state = false
        return false
    end
    if quest_menu_last_state then
        return true
    end

    local parts_ok, parts = pcall(function() return gui:get_field("_QuestListParts") end)
    if not parts_ok then return quest_menu_last_state end
    if parts == nil then
        quest_menu_last_state = false
        return false
    end

    local active_ok, active = pcall(function() return parts:call("get_IsActive") end)
    if not active_ok then return quest_menu_last_state end
    quest_menu_last_state = active == true
    return quest_menu_last_state
end
local function update_normal_runtime_menu_pause()
    local menu_open = read_quest_fullscreen_open()
    local now = os.clock()
    if menu_open then
        if not normal_runtime_menu_suspended then
            normal_runtime_menu_suspended = true
            normal_runtime_pause_started = now
        end
        return true
    end
    if normal_runtime_menu_suspended then
        if normal_runtime_pause_started then
            normal_runtime_paused_time = normal_runtime_paused_time + (now - normal_runtime_pause_started)
        end
        normal_runtime_pause_started = nil
        normal_runtime_menu_suspended = false
    end
    return false
end

 
 
 
 

local last_armor_variant_sync_time = 0
local CHARACTER_EDIT_HASHES = {
    { name = "Main", hash = 4175418299 },
    { name = "Face", hash = 935285574 },
    { name = "Helm", hash = 1437951306 },
    { name = "Chest", hash = 3471977595 },
    { name = "Arms", hash = 2156620752 },
    { name = "Waist", hash = 639293466 },
    { name = "Legs", hash = 1274174449 },
    { name = "Slinger", hash = 2517189864 }
}

local FACE_BIND_PART_NAMES = {
    [1] = "Chest",
    [2] = "Arms",
    [3] = "Waist",
    [4] = "Legs"
}

local stats = {
    seen = 0,
    matched = 0,
    inspected = 0,
    stage_attempts = 0,
    stage_ok = 0,
    candidates_ready = 0,
    manual_targets = 0,
    auto_targets = 0,
    bone_system_configs = 0,
    dictionary_generation = 0,
    armor_variant_attempts = 0,
    armor_variant_ok = 0,
    last_error = "",
    last_skip = "",
    last_status = "idle"
}


local Localization = {
    en = {
        language = "Language",
        enabled = "Enable BoneSystemForNPC",
        advanced = "Advanced options",
        debug = "Debug",
        auto_apply_face_mapping = "Use BoneSystem face/expression mapping",
        auto_sync_armor_variant = "Sync AVM variants to matched NPCs",
        write_report = "Write report",
        debug_log = "Debug log",
        reload_config = "Reload config and targets",
        write_report_now = "Write report now",
        status = "Status",
        targets = "Targets",
        scan = "BoneSystem scan",
        avm = "AVM",
        api = "API",
        language_zh = "Chinese",
        language_en = "English"
    },
    zh = {
        language = "语言 / Language",
        enabled = "启用 BoneSystemForNPC",
        advanced = "高级选项",
        debug = "调试",
        auto_apply_face_mapping = "使用 BoneSystem 脸部/表情映射",
        auto_sync_armor_variant = "同步 AVM 差分到命中 NPC",
        write_report = "写出报告",
        debug_log = "调试日志",
        reload_config = "重新读取配置和目标",
        write_report_now = "立即写报告",
        status = "状态",
        targets = "目标",
        scan = "BoneSystem 扫描",
        avm = "AVM 差分",
        api = "API",
        language_zh = "中文",
        language_en = "English"
    }
}

 
 
 
 

local function T(key)
    local lang = (config and config.language) or "zh"
    local table_for_lang = Localization[lang] or Localization.zh
    return table_for_lang[key] or Localization.en[key] or tostring(key)
end

local function bs_log(message)
    if config and config.debug_log and log and log.info then
        log.info("[" .. MOD_NAME .. "] " .. tostring(message))
    end
end

local function copy_table(value)
    local out = {}
    for k, v in pairs(value) do
        if type(v) == "table" then
            out[k] = copy_table(v)
        else
            out[k] = v
        end
    end
    return out
end

local function merge_defaults(dst, src)
    for k, v in pairs(src) do
        if dst[k] == nil then
            if type(v) == "table" then
                dst[k] = copy_table(v)
            else
                dst[k] = v
            end
        end
    end
end

local function trim_text(value, max_len)
    local text = tostring(value or "")
    max_len = max_len or 240
    if string.len(text) > max_len then
        return string.sub(text, 1, max_len) .. "..."
    end
    return text
end

local function sanitize_report_value(value, depth)
    depth = depth or 0
    if depth > 16 then
        return trim_text(value, 400)
    end
    local value_type = type(value)
    if value_type == "string" then
        local text = trim_text(value, 2000)
        return (string.gsub(text, "[^\32-\126]", "?"))
    end
    if value_type == "number" or value_type == "boolean" or value == nil then
        return value
    end
    if value_type ~= "table" then
        local text = trim_text(tostring(value), 400)
        return (string.gsub(text, "[^\32-\126]", "?"))
    end
    local out = {}
    for k, v in pairs(value) do
        local key = k
        if type(k) == "string" then
            key = sanitize_report_value(k, depth + 1)
        elseif type(k) ~= "number" then
            key = sanitize_report_value(tostring(k), depth + 1)
        end
        out[key] = sanitize_report_value(v, depth + 1)
    end
    return out
end
local function record_event(kind, detail)
    table.insert(diagnostics.events, { time = os.clock(), kind = tostring(kind or "event"), detail = trim_text(detail, 700) })
    while #diagnostics.events > 80 do
        table.remove(diagnostics.events, 1)
    end
end

 
 
 
 

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

 
 
 
 

local function diagnostic_status(tag, message)
    record_event(tag, message)
    bs_log("[" .. tostring(tag) .. "] " .. tostring(message))
end

local function remember_collision(kind, key, kept, ignored)
    local collision = {
        time = os.clock(),
        kind = tostring(kind),
        key = tostring(key),
        kept = tostring(kept or ""),
        ignored = tostring(ignored or "")
    }
    table.insert(diagnostics.collisions, collision)
    while #diagnostics.collisions > 24 do
        table.remove(diagnostics.collisions, 1)
    end
    bs_log("[Collision] kind=" .. collision.kind .. " key=" .. collision.key .. " kept=" .. collision.kept .. " ignored=" .. collision.ignored)
end

local function remember_operation(operation)
    table.insert(diagnostics.operations, operation)
    while #diagnostics.operations > 16 do
        table.remove(diagnostics.operations, 1)
    end
end

local function get_targets()
    if target_cache then
        return target_cache
    end
    local result = {}
    if type(config.targets) == "table" then
        for _, target in ipairs(config.targets) do
            if target.enabled ~= false then
                table.insert(result, target)
            end
        end
    end
    target_cache = result
    return result
end

local function write_report(force)
    if config.write_report == false or not json or not json.dump_file then
        return
    end
    local now = os.clock()
    local interval = tonumber(config.report_interval) or 1.0
    if not force and now - diagnostics.last_report_time < interval then
        return
    end
    diagnostics.last_report_time = now
    pcall(function()
        local report = {
            mod = MOD_NAME,
            version = VERSION,
            api_present = type(API) == "table",
            api_fix_bone_type = type(API.fix_bone),
            api_load_data_type = type(API.load_data),
            enabled = config.enabled,
            mode = config.mode,
            enable_native_fix = config.enable_native_fix == true,
            dictionary_generation = dictionary_generation,
            bone_scan_status = diagnostics.bone_scan_status,
            bone_index_status = diagnostics.bone_index_status,
            auto_dictionary_count = stats.auto_targets,
            target_scan_status = diagnostics.target_scan_status,
            target_index_status = diagnostics.target_index_status,
            manual_dictionary_count = stats.manual_targets,
            auto_dictionary_source = diagnostics.auto_dictionary_source,
            manual_dictionary_source = diagnostics.manual_dictionary_source,
            performance = performance,
            recent_unmatched = diagnostics.recent_unmatched,
            collisions = diagnostics.collisions,
            hook_state = hook_state,
            stats = stats,
            targets = get_targets(),
            inspections = diagnostics.inspections,
            operations = diagnostics.operations,
            target_files = diagnostics.target_files,
            bone_system_scan = diagnostics.bone_system_scan,
            manual_targets = diagnostics.manual_targets,
            auto_targets = diagnostics.auto_targets,
            target_manual_overrides = diagnostics.target_manual_overrides,
            armor_variant = diagnostics.armor_variant,
            scene_transition = diagnostics.scene_transition,
            event_model_setups = diagnostics.event_model_setups,
            events = diagnostics.events
        }
        json.dump_file(REPORT_PATH, sanitize_report_value(report, 0))
    end)
end

 
 
 
 

local function safe_call(obj, method_name, ...)
    if not obj or type(method_name) ~= "string" then
        return false, nil
    end
    local args = { ... }
    local ok, result = pcall(function()
        return obj:call(method_name, unpack_args(args))
    end)
    if ok then
        return true, result
    end
    stats.last_error = tostring(result)
    return false, result
end

local function direct_call(obj, method_name, ...)
    if not obj or type(method_name) ~= "string" then
        return false, nil
    end
    local args = { ... }
    local ok, result = pcall(function()
        local fn = obj[method_name]
        if type(fn) == "function" then
            return fn(obj, unpack_args(args))
        end
        return nil
    end)
    if ok then
        return true, result
    end
    stats.last_error = tostring(result)
    return false, result
end

local function call_any(obj, method_name, ...)
    local ok, result = safe_call(obj, method_name, ...)
    if ok then
        return true, result
    end
    return direct_call(obj, method_name, ...)
end

local function safe_field(obj, field_name)
    if not obj or type(field_name) ~= "string" then
        return false, nil
    end
    local ok, result = pcall(function()
        return obj:get_field(field_name)
    end)
    if ok then
        return true, result
    end
    stats.last_error = tostring(result)
    return false, result
end

local function safe_sdk_type(type_name)
    if type_cache[type_name] ~= nil then
        return type_cache[type_name]
    end
    local ok, td = pcall(sdk.find_type_definition, type_name)
    if ok and td then
        type_cache[type_name] = td
        return td
    end
    type_cache[type_name] = false
    return nil
end

 
local function install_scene_transition_hook()
    local td = safe_sdk_type("app.EnvironmentManager")
    if not td then
        hook_state.scene = "app.EnvironmentManager not found; SceneManager polling fallback active"
        return false
    end
    local method = nil
    local ok_method = pcall(function()
        method = td:get_method("evSceneLoadBefore()") or td:get_method("evSceneLoadBefore")
    end)
    if not ok_method or not method then
        hook_state.scene = "evSceneLoadBefore not found; SceneManager polling fallback active"
        return false
    end
    local ok_hook, err = pcall(function()
        sdk.hook(method, function()
            scene_transition.mark_start("app.EnvironmentManager.evSceneLoadBefore")
        end)
    end)
    if not ok_hook then
        hook_state.scene = tostring(err)
        return false
    end
    scene_transition_hook_installed = true
    local end_td = safe_sdk_type("app.PlayerManager")
    if end_td then
        for _, method_name in ipairs({
            "evSceneLoadEnd()",
            "evSceneLoadEnd_FastTravel()",
            "evSceneLoadEnd_SceneTransition()",
            "evSceneLoadEnd_ThroughJunction()"
        }) do
            local end_method_name = method_name
            local end_reason = "app.PlayerManager." .. end_method_name
            local end_method = nil
            pcall(function()
                end_method = end_td:get_method(end_method_name)
            end)
            if end_method then
                local ok_end = pcall(function()
                    sdk.hook(end_method, function()
                    end, function(retval)
                        scene_transition.mark_end(end_reason)
                        return retval
                    end)
                end)
                if ok_end then
                    scene_transition.end_hook_count = scene_transition.end_hook_count + 1
                end
            end
        end
    end
    local fade_hook_installed = false
    local fade_td = safe_sdk_type("app.CameraManager")
    local fade_method = nil
    if fade_td then
        pcall(function()
            fade_method = fade_td:get_method("onSceneLoadFadeIn()") or fade_td:get_method("onSceneLoadFadeIn")
        end)
    end
    if fade_method then
        fade_hook_installed = pcall(function()
            sdk.hook(fade_method, function()
                return sdk.PreHookResult.CALL_ORIGINAL
            end, function(retval)
                if scene_transition.active and scene_transition.requires_fade_in then
                    scene_transition.mark_end("app.CameraManager.onSceneLoadFadeIn", true)
                end
                return retval
            end)
        end)
        if fade_hook_installed then
            scene_transition.fade_in_end_hook_count = 1
        end
    end
    if fade_hook_installed then
        local fast_travel_td = safe_sdk_type("app.mcFastTravel")
        local setup_loading_method = nil
        if fast_travel_td then
            pcall(function()
                setup_loading_method = fast_travel_td:get_method("setupLoadingEvent")
            end)
        end
        if setup_loading_method then
            local ok_black_start = pcall(function()
                sdk.hook(setup_loading_method, function()
                    if not scene_transition.active then
                        scene_transition.mark_start("app.mcFastTravel.setupLoadingEvent", true)
                    end
                    return sdk.PreHookResult.CALL_ORIGINAL
                end, function(retval)
                    return retval
                end)
            end)
            if ok_black_start then
                scene_transition.black_screen_start_hook_count = 1
            end
        end
    end
    hook_state.scene = "installed app.EnvironmentManager.evSceneLoadBefore minimal quarantine trigger; PlayerManager load-end hooks=" .. tostring(scene_transition.end_hook_count)
        .. "; black-screen start hooks=" .. tostring(scene_transition.black_screen_start_hook_count)
        .. "; fade-in end hooks=" .. tostring(scene_transition.fade_in_end_hook_count)
        .. "; SceneManager fallback polling disabled"
    record_event("hook", hook_state.scene)
    return true
end

local function get_runtime_type(type_name)
    local td = safe_sdk_type(type_name)
    if td then
        local ok_rt, rt = pcall(function()
            return td:get_runtime_type()
        end)
        if ok_rt and rt then
            return rt
        end
    end
    if sdk and sdk.typeof then
        local ok_typeof, rt = pcall(sdk.typeof, type_name)
        if ok_typeof and rt then
            return rt
        end
    end
    return nil
end

local function is_valid_managed_object(obj)
    if not obj then
        return false
    end
    if sdk and sdk.is_managed_object then
        local ok, result = pcall(sdk.is_managed_object, obj)
        return ok and result == true
    end
    return true
end
local function get_game_object(obj)
    if not obj then
        return nil
    end
    local ok, game_obj = safe_call(obj, "get_GameObject")
    if ok and game_obj then
        return game_obj
    end
    ok, game_obj = safe_field(obj, "_GameObject")
    if ok and game_obj then
        return game_obj
    end
    ok, game_obj = safe_call(obj, "get_GameObject(System.Boolean)", true)
    if ok and game_obj then
        return game_obj
    end
    return nil
end

local function get_transform(game_obj)
    if not game_obj then
        return nil
    end
    local ok, transform = safe_call(game_obj, "get_Transform")
    if ok and transform then
        return transform
    end
    ok, transform = safe_call(game_obj, "get_transform")
    if ok and transform then
        return transform
    end
    return nil
end

local function get_game_object_name(game_obj)
    if not game_obj then
        return ""
    end
    local ok, name = safe_call(game_obj, "get_Name")
    if ok and name then
        return tostring(name)
    end
    ok, name = safe_call(game_obj, "get_name")
    if ok and name then
        return tostring(name)
    end
    return ""
end

local function lower_contains(text, needle)
    if not text or not needle or needle == "" then
        return false
    end
    return string.find(string.lower(tostring(text)), string.lower(tostring(needle)), 1, true) ~= nil
end

 
 
 
 

local function normalize_target_path(path)
    local text = tostring(path or "")
    text = string.gsub(text, "\\", "/")
    text = string.gsub(text, "^%./", "")
    return text
end

local function canonical_data_path(path)
    local normalized = normalize_target_path(path)
    local lower = string.lower(normalized)
    local prefix = "reframework/data/"
    if string.sub(lower, 1, string.len(prefix)) == prefix then
        return string.sub(normalized, string.len(prefix) + 1)
    end
    return normalized
end

local function file_name_from_path(path)
    local normalized = normalize_target_path(path)
    return string.match(normalized, "([^/]+)$") or normalized
end

local function file_stem_from_path(path)
    return string.gsub(file_name_from_path(path), "%.json$", "")
end

local function is_npc_target_id(value)
    return type(value) == "string" and string.match(value, "^NPC%d+_%d+_%d+$") ~= nil
end

local function npc_id_from_target_path(path)
    local stem = file_stem_from_path(path)
    if is_npc_target_id(stem) then
        return stem
    end
    return nil
end

local function body_id_from_bone_config_path(path)
    return string.match(file_name_from_path(path), "^(ch%d%d_%d%d%d_%d%d%d%d)%.json$")
end

local function body_id_from_index_entry(entry)
    if type(entry) == "string" then
        return string.match(entry, "(ch%d%d_%d%d%d_%d%d%d%d)")
    end
    if type(entry) == "table" then
        return body_id_from_index_entry(entry.body_id or entry.id or entry.name or entry.path or entry.file)
    end
    return nil
end

local function path_preference(path, expected)
    if string.lower(canonical_data_path(path)) == string.lower(expected) then
        return 2
    end
    return 1
end

local function load_json_file(path)
    if not json or type(json.load_file) ~= "function" then
        return nil, "json.load_file unavailable"
    end
    local ok, data = pcall(function()
        return json.load_file(path)
    end)
    if ok and type(data) == "table" then
        return data, path
    end
    local canonical = canonical_data_path(path)
    if canonical ~= normalize_target_path(path) then
        local ok_canonical, canonical_data = pcall(function()
            return json.load_file(canonical)
        end)
        if ok_canonical and type(canonical_data) == "table" then
            return canonical_data, canonical
        end
        return nil, tostring(canonical_data)
    end
    return nil, tostring(data)
end

local function append_target(result, target, source_path)
    if type(target) ~= "table" or target.enabled == false then
        return 0
    end
    if target.enabled == nil then
        target.enabled = true
    end
    local file_npc_id = npc_id_from_target_path(source_path)
    local configured_npc_id = target.npc_id and tostring(target.npc_id) or nil
    if configured_npc_id == "" then
        configured_npc_id = nil
    end
    local npc_id = configured_npc_id or file_npc_id
    if not is_npc_target_id(npc_id) then
        record_event("target_skipped_invalid_npc_id", tostring(source_path or ""))
        return 0
    end
    if file_npc_id and configured_npc_id and configured_npc_id ~= file_npc_id then
        record_event("target_skipped_npc_id_mismatch", tostring(source_path or "") .. "; npc_id=" .. configured_npc_id)
        return 0
    end
    target.npc_id = npc_id
    target.source_file = canonical_data_path(source_path)
    table.insert(result, target)
    return 1
end

local function append_targets_from_data(result, data, source_path)
    if type(data) ~= "table" then
        return 0
    end
    local before = #result
    if type(data.targets) == "table" then
        for _, target in ipairs(data.targets) do
            append_target(result, target, source_path)
        end
    elseif type(data[1]) == "table" then
        for _, target in ipairs(data) do
            append_target(result, target, source_path)
        end
    else
        append_target(result, data, source_path)
    end
    return #result - before
end

local function load_target_file(path, result)
    local canonical = string.lower(canonical_data_path(path))
    if loaded_target_paths[canonical] then
        return 0
    end
    loaded_target_paths[canonical] = true
    local data, loaded_path_or_error = load_json_file(path)
    if type(data) ~= "table" then
        record_event("target_load_failed", tostring(path) .. ": " .. trim_text(loaded_path_or_error, 300))
        return 0
    end
    local count = append_targets_from_data(result, data, loaded_path_or_error)
    table.insert(diagnostics.target_files, { path = loaded_path_or_error, targets = count })
    return count
end

local function load_main_config()
    local data, loaded_path_or_error = load_json_file(CONFIG_PATH)
    local next_config = type(data) == "table" and data or {}
    merge_defaults(next_config, default_config)
     
    next_config.manual_targets_enabled = nil
    next_config.auto_discover_bonesystem_outfits = nil
    if type(data) == "table" then
        record_event("config_loaded", loaded_path_or_error)
    else
        record_event("config_default", trim_text(loaded_path_or_error, 300))
    end
    return next_config
end

 
local function replace_index_snapshot(path, payload)
    if not json or type(json.dump_file) ~= "function" then
        return false, "json.dump_file unavailable"
    end
    local ok, err = pcall(function()
        json.dump_file(path, payload)
    end)
    if not ok then
        return false, trim_text(err, 300)
    end
    return true, "updated"
end

local function load_bone_system_index_snapshot()
    local result = {}
    local seen = {}
    if config.use_bone_system_index == false then
        return result, false, "disabled"
    end
    local path = config.bone_system_index_path or BONE_SYSTEM_INDEX_PATH
    local data, loaded_path_or_error = load_json_file(path)
    if type(data) ~= "table" then
        return result, false, trim_text(loaded_path_or_error, 300)
    end
    local raw = data.body_ids or data.files or data
    if type(raw) ~= "table" then
        return result, false, "index has no body_ids"
    end
    for _, entry in ipairs(raw) do
        local body_id = body_id_from_index_entry(entry)
        if body_id and not seen[body_id] then
            seen[body_id] = true
            table.insert(result, body_id)
        end
    end
    table.sort(result)
    return result, #result > 0, loaded_path_or_error
end

 
local function scan_bone_system_configs()
    local scan = {
        patterns = {},
        paths = {},
        body_ids = {},
        files_by_body_id = {},
        errors = {},
        invalid = 0,
        successful_patterns = 0
    }
    local seen_paths = {}
    local patterns = config.bone_system_scan_patterns or DEFAULT_BONE_SYSTEM_SCAN_PATTERNS
    if not fs or type(fs.glob) ~= "function" then
        table.insert(scan.errors, "fs.glob unavailable")
    else
        for _, pattern in ipairs(patterns) do
            local pattern_report = { pattern = tostring(pattern), count = 0 }
            local ok, globbed = pcall(function()
                return fs.glob(pattern)
            end)
            if ok and type(globbed) == "table" then
                scan.successful_patterns = scan.successful_patterns + 1
                pattern_report.count = #globbed
                for _, path in ipairs(globbed) do
                    local normalized = canonical_data_path(path)
                    local path_key = string.lower(normalized)
                    if normalized ~= "" and not seen_paths[path_key] then
                        seen_paths[path_key] = true
                        table.insert(scan.paths, normalized)
                        local body_id = body_id_from_bone_config_path(normalized)
                        if body_id then
                            local expected = "BoneSystem/" .. body_id .. ".json"
                            local current = scan.files_by_body_id[body_id]
                            if not current then
                                scan.files_by_body_id[body_id] = normalized
                            else
                                local current_score = path_preference(current, expected)
                                local new_score = path_preference(normalized, expected)
                                if new_score > current_score then
                                    scan.files_by_body_id[body_id] = normalized
                                    remember_collision("bone_system", body_id, normalized, current)
                                else
                                    remember_collision("bone_system", body_id, current, normalized)
                                end
                            end
                        else
                            scan.invalid = scan.invalid + 1
                        end
                    end
                end
            else
                pattern_report.error = trim_text(globbed, 240)
                table.insert(scan.errors, tostring(pattern) .. ": " .. pattern_report.error)
            end
            table.insert(scan.patterns, pattern_report)
        end
    end
    for body_id in pairs(scan.files_by_body_id) do
        table.insert(scan.body_ids, body_id)
    end
    table.sort(scan.body_ids)
    scan.live_success = scan.successful_patterns > 0 and #scan.body_ids > 0
    diagnostics.bone_system_scan = scan
    diagnostics.bone_scan_status = scan.live_success and "live_success" or "live_failed"
    diagnostic_status("BoneScan", "status=" .. diagnostics.bone_scan_status .. " valid=" .. tostring(#scan.body_ids) .. " invalid=" .. tostring(scan.invalid))
    return scan
end

 
local function rebuild_auto_dictionary()
    auto_by_body_id = {}
    local old_ids, old_loaded = load_bone_system_index_snapshot()
    local scan = scan_bone_system_configs()
    local source_ids = nil
    local source_files = {}
    if scan.live_success then
        source_ids = scan.body_ids
        source_files = scan.files_by_body_id
        local ok_write, write_status = replace_index_snapshot(
            config.bone_system_index_path or BONE_SYSTEM_INDEX_PATH,
            {
                version = 1,
                source = "generated_from_live_bone_system_scan",
                generated_on = os.date("%Y-%m-%d"),
                body_ids = scan.body_ids
            }
        )
        diagnostics.bone_index_status = ok_write and "updated" or "write_failed"
        diagnostic_status("BoneIndex", "status=" .. diagnostics.bone_index_status .. " old=" .. tostring(#old_ids) .. " new=" .. tostring(#scan.body_ids) .. (ok_write and "" or " reason=" .. tostring(write_status)))
        diagnostics.auto_dictionary_source = "live"
    elseif old_loaded then
        source_ids = old_ids
        for _, body_id in ipairs(old_ids) do
            source_files[body_id] = "BoneSystem/" .. body_id .. ".json"
        end
        diagnostics.bone_index_status = "preserved"
        diagnostics.auto_dictionary_source = "index"
        diagnostic_status("BoneIndex", "status=preserved count=" .. tostring(#old_ids))
    else
        source_ids = {}
        diagnostics.bone_index_status = "unavailable"
        diagnostics.auto_dictionary_source = "none"
        diagnostic_status("BoneIndex", "status=unavailable")
    end

    for _, body_id in ipairs(source_ids) do
        auto_by_body_id[body_id] = {
            enabled = true,
            body_id = body_id,
            bone_system_body_id = body_id,
            private_face_mode = config.default_private_face_mode == true,
            auto_target = true,
            source_file = source_files[body_id] or ("BoneSystem/" .. body_id .. ".json")
        }
    end
    local targets = {}
    for _, body_id in ipairs(source_ids) do
        local target = auto_by_body_id[body_id]
        if target then
            table.insert(targets, target)
        end
    end
    diagnostics.auto_targets = targets
    stats.auto_targets = #targets
    stats.bone_system_configs = #source_ids
    local dictionary_status = diagnostics.auto_dictionary_source == "live" and "ready"
        or (diagnostics.auto_dictionary_source == "index" and "degraded_ready" or "unavailable")
    diagnostic_status("AutoDict", "status=" .. dictionary_status .. " count=" .. tostring(#targets) .. " source=" .. diagnostics.auto_dictionary_source .. " generation=" .. tostring(dictionary_generation))
end

local function scan_target_paths()
    local scan = {
        patterns = {},
        paths = {},
        errors = {},
        successful_patterns = 0,
        raw_count = 0
    }
    local seen = {}
    if not fs or type(fs.glob) ~= "function" then
        table.insert(scan.errors, "fs.glob unavailable")
    else
        for _, pattern in ipairs(TARGETS_GLOB_PATTERNS) do
            local pattern_report = { pattern = tostring(pattern), count = 0 }
            local ok, globbed = pcall(function()
                return fs.glob(pattern)
            end)
            if ok and type(globbed) == "table" then
                scan.successful_patterns = scan.successful_patterns + 1
                pattern_report.count = #globbed
                scan.raw_count = scan.raw_count + #globbed
                for _, path in ipairs(globbed) do
                    local normalized = canonical_data_path(path)
                    local key = string.lower(normalized)
                    if normalized ~= "" and not seen[key] then
                        seen[key] = true
                        table.insert(scan.paths, normalized)
                    end
                end
            else
                pattern_report.error = trim_text(globbed, 240)
                table.insert(scan.errors, tostring(pattern) .. ": " .. pattern_report.error)
            end
            table.insert(scan.patterns, pattern_report)
        end
    end
    table.sort(scan.paths)
    scan.live_success = scan.successful_patterns > 0 and scan.raw_count > 0
    diagnostics.target_scan_status = scan.live_success and "live_success" or "live_failed"
    diagnostic_status("TargetScan", "status=" .. diagnostics.target_scan_status .. " raw=" .. tostring(scan.raw_count))
    return scan
end

local function load_target_index_paths()
    local paths = {}
    local data, loaded_path_or_error = load_json_file(TARGET_INDEX_PATH)
    if type(data) ~= "table" then
        return paths, false, trim_text(loaded_path_or_error, 300)
    end
    local raw = data.files or data
    if type(raw) ~= "table" then
        return paths, false, "index has no files"
    end
    local seen = {}
    for _, entry in ipairs(raw) do
        local value = type(entry) == "table" and (entry.path or entry.file or entry.name) or entry
        if type(value) == "string" and value ~= "" then
            local path = string.find(value, "[/\\]") and canonical_data_path(value) or (TARGETS_DIR .. "/" .. value)
            local key = string.lower(path)
            if not seen[key] then
                seen[key] = true
                table.insert(paths, path)
            end
        end
    end
    table.sort(paths)
    return paths, true, loaded_path_or_error
end

local function build_manual_dictionary_from_paths(paths)
    local candidates = {}
    loaded_target_paths = {}
    for _, path in ipairs(paths or {}) do
        local file_name = string.lower(file_name_from_path(path))
        if file_name ~= "example.json" and file_name ~= "_index.json" and file_name ~= "targetindex.json" then
            load_target_file(path, candidates)
        end
    end
    local selected = {}
    for _, target in ipairs(candidates) do
        local npc_id = target.npc_id
        local current = selected[npc_id]
        if not current then
            selected[npc_id] = target
        else
            local expected = TARGETS_DIR .. "/" .. npc_id .. ".json"
            local current_score = path_preference(current.source_file, expected)
            local new_score = path_preference(target.source_file, expected)
            if new_score > current_score then
                selected[npc_id] = target
                remember_collision("manual_target", npc_id, target.source_file, current.source_file)
            else
                remember_collision("manual_target", npc_id, current.source_file, target.source_file)
            end
        end
    end
    return selected
end

local function sorted_manual_targets(dictionary)
    local ids = {}
    for npc_id in pairs(dictionary or {}) do
        table.insert(ids, npc_id)
    end
    table.sort(ids)
    local targets = {}
    local files = {}
    for _, npc_id in ipairs(ids) do
        table.insert(targets, dictionary[npc_id])
        table.insert(files, npc_id .. ".json")
    end
    return targets, files
end

 
local function rebuild_manual_dictionary()
    manual_by_npc_id = {}
    local scan = scan_target_paths()
    local paths = nil
    if scan.live_success then
        paths = scan.paths
        diagnostics.manual_dictionary_source = "live"
        local live_dictionary = build_manual_dictionary_from_paths(paths)
        local _, files = sorted_manual_targets(live_dictionary)
        local ok_write, write_status = replace_index_snapshot(
            TARGET_INDEX_PATH,
            {
                version = 1,
                source = "generated_from_live_target_scan",
                generated_on = os.date("%Y-%m-%d"),
                files = files
            }
        )
        diagnostics.target_index_status = ok_write and "updated" or "write_failed"
        diagnostic_status("TargetIndex", "status=" .. diagnostics.target_index_status .. " files=" .. tostring(#files) .. (ok_write and "" or " reason=" .. tostring(write_status)))
        manual_by_npc_id = live_dictionary
    else
        local index_paths, index_loaded = load_target_index_paths()
        if index_loaded then
            paths = index_paths
            diagnostics.target_index_status = "preserved"
            diagnostics.manual_dictionary_source = "index"
            diagnostic_status("TargetIndex", "status=preserved files=" .. tostring(#index_paths))
            manual_by_npc_id = build_manual_dictionary_from_paths(index_paths)
        else
            diagnostics.target_index_status = "unavailable"
            diagnostics.manual_dictionary_source = "none"
            diagnostic_status("TargetIndex", "status=unavailable")
        end
        diagnostics.manual_targets = sorted_manual_targets(manual_by_npc_id)
    end
    local manual_targets = sorted_manual_targets(manual_by_npc_id)
    diagnostics.manual_targets = manual_targets
    stats.manual_targets = #manual_targets
    local dictionary_status = diagnostics.manual_dictionary_source == "live" and "ready"
        or (diagnostics.manual_dictionary_source == "index" and "degraded_ready" or "unavailable")
    diagnostic_status("ManualDict", "status=" .. dictionary_status .. " count=" .. tostring(#manual_targets) .. " source=" .. diagnostics.manual_dictionary_source .. " generation=" .. tostring(dictionary_generation))
end

 
local function load_config()
    config = load_main_config()
    dictionary_generation = dictionary_generation + 1
    stats.dictionary_generation = dictionary_generation
    diagnostics.target_files = {}
    diagnostics.manual_targets = {}
    diagnostics.auto_targets = {}
    diagnostics.collisions = {}
    diagnostics.bone_system_scan = {}
    rebuild_manual_dictionary()
    rebuild_auto_dictionary()

    local combined = {}
    for _, target in ipairs(diagnostics.manual_targets) do
        table.insert(combined, target)
    end
    for _, target in ipairs(diagnostics.auto_targets) do
        table.insert(combined, target)
    end
    config.targets = combined
    target_cache = nil
end

 
 
 
 

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
         
        local root_identity = tostring(root_obj or "")
        if root_identity ~= "" and root_identity ~= identity then
            identity = identity .. "@" .. root_identity
        end
    end
    return table.concat({ tostring(dictionary_generation), identity, chest_body_id, chest_name }, "|")
end

 
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

 
 
 
 

local function use_private_face_mode(target)
    if config.auto_apply_face_mapping == false then
        return true
    end
    if target and target.private_face_mode ~= nil then
        return target.private_face_mode == true
    end
    return config.default_private_face_mode == true
end

 
local function make_target_bone_data(bone_data, target)
    if type(bone_data) ~= "table" then
        return bone_data, false, "bonesystem"
    end
    local private_mode = use_private_face_mode(target)
    if not private_mode then
        return bone_data, false, "bonesystem"
    end
    local api_bone_data = {}
    for key, value in pairs(bone_data) do
        api_bone_data[key] = value
    end
    api_bone_data.HideFace = false
    api_bone_data.BindFace = false
    return api_bone_data, true, "private"
end

local function probe_call(obj, method_name, ...)
    if not obj or type(method_name) ~= "string" then
        return false, nil
    end
    local args = { ... }
    local ok, result = pcall(function()
        return obj:call(method_name, unpack_args(args))
    end)
    if ok then
        return true, result
    end
    local ok_direct, direct_result = pcall(function()
        local fn = obj[method_name]
        if type(fn) == "function" then
            return fn(obj, unpack_args(args))
        end
        return nil
    end)
    if ok_direct then
        return true, direct_result
    end
    return false, result or direct_result
end

local function get_component_quiet(game_obj, type_name)
    local rt = get_runtime_type(type_name)
    if not rt then
        return nil
    end
    local ok, component = probe_call(game_obj, "getComponent(System.Type)", rt)
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

local function get_game_object_quiet(obj)
    if not obj then
        return nil
    end
    local ok, game_obj = probe_call(obj, "get_GameObject")
    if ok and game_obj then
        return game_obj
    end
    ok, game_obj = pcall(function()
        return obj:get_field("_GameObject")
    end)
    if ok and game_obj then
        return game_obj
    end
    return nil
end

local function get_game_object_name_quiet(game_obj)
    if not game_obj then
        return ""
    end
    local ok, name = probe_call(game_obj, "get_Name")
    if ok and name then
        return tostring(name)
    end
    ok, name = probe_call(game_obj, "get_name")
    if ok and name then
        return tostring(name)
    end
    return ""
end

local function summarize_object_for_trace(obj)
    local game_obj = get_game_object_quiet(obj) or obj
    return {
        object = tostring(obj),
        game_object = tostring(game_obj),
        name = get_game_object_name_quiet(game_obj),
        has_motion = get_component_quiet(game_obj, "via.motion.Motion") ~= nil,
        has_child_secondary = get_component_quiet(game_obj, "via.motion.ChildSecondary") ~= nil,
        has_custom_skeleton = get_component_quiet(game_obj, "via.motion.CustomSkeleton") ~= nil,
        has_edit_region = get_component_quiet(game_obj, "app.CharacterEditRegion") ~= nil,
        has_edit_region_root = get_component_quiet(game_obj, "app.CharacterEditRegionRoot") ~= nil
    }
end

local function probe_character_edit_root(root, label, bind_part_name)
    local report = {
        label = tostring(label or "root"),
        object = tostring(root),
        face_part_ok = false,
        bind_part_name = tostring(bind_part_name or ""),
        bind_part_ok = false,
        parts = {}
    }
    if not root then
        report.error = "no CharacterEditRegionRoot"
        return report
    end
    for _, spec in ipairs(CHARACTER_EDIT_HASHES) do
        local entry = { hash = spec.hash, ok = false }
        local ok_part, part = probe_call(root, "getPartsObject", spec.hash)
        if ok_part and part then
            entry.ok = true
            entry.part = summarize_object_for_trace(part)
        else
            entry.error = trim_text(part, 180)
        end
        report.parts[spec.name] = entry
        if spec.name == "Face" and entry.ok then
            report.face_part_ok = true
        end
        if spec.name == bind_part_name and entry.ok then
            report.bind_part_ok = true
        end
    end
    return report
end

local function probe_edit_region_source(obj, label, bind_part_name)
    local game_obj = get_game_object_quiet(obj) or obj
    local source = {
        label = tostring(label or ""),
        object = tostring(obj),
        game_object = tostring(game_obj),
        name = get_game_object_name_quiet(game_obj),
        components = {},
        roots = {},
        face_part_ok = false,
        bind_part_name = tostring(bind_part_name or ""),
        bind_part_ok = false
    }
    if not game_obj then
        source.error = "no game object"
        return source
    end
    local root_component = get_component_quiet(game_obj, "app.CharacterEditRegionRoot")
    source.components.CharacterEditRegionRoot = root_component ~= nil
    if root_component then
        local root_report = probe_character_edit_root(root_component, "component:CharacterEditRegionRoot", bind_part_name)
        table.insert(source.roots, root_report)
        source.face_part_ok = source.face_part_ok or root_report.face_part_ok
        source.bind_part_ok = source.bind_part_ok or root_report.bind_part_ok
    end
    local region = get_component_quiet(game_obj, "app.CharacterEditRegion")
    source.components.CharacterEditRegion = region ~= nil
    if region then
        local ok_root, region_root = probe_call(region, "getRoot")
        source.region_getRoot_ok = ok_root and region_root ~= nil
        if ok_root and region_root then
            local root_report = probe_character_edit_root(region_root, "component:CharacterEditRegion.getRoot", bind_part_name)
            table.insert(source.roots, root_report)
            source.face_part_ok = source.face_part_ok or root_report.face_part_ok
            source.bind_part_ok = source.bind_part_ok or root_report.bind_part_ok
        else
            source.region_getRoot_error = trim_text(region_root, 180)
        end
    end
    return source
end

 
local function build_edit_region_trace(character, root_obj, candidates, bone_data, target)
    if config.edit_region_trace == false then
        return nil
    end
    local bind_part = 1
    if type(bone_data) == "table" and tonumber(bone_data.BindPart) then
        bind_part = tonumber(bone_data.BindPart)
    end
    local bind_part_name = FACE_BIND_PART_NAMES[bind_part] or tostring(bind_part)
    local trace = {
        enabled = true,
        auto_apply_face_mapping = config.auto_apply_face_mapping ~= false,
        private_face_mode = use_private_face_mode(target),
        bind_part = bind_part,
        bind_part_name = bind_part_name,
        root = probe_edit_region_source(root_obj, "root_game_object", bind_part_name),
        character_parts = {},
        candidates = {}
    }
    for index = 0, 5 do
        local entry = { index = index, ok = false }
        local ok_part, part = probe_call(character, "getParts", index)
        if ok_part and part then
            entry.ok = true
            entry.part = summarize_object_for_trace(part)
            entry.edit_region = probe_edit_region_source(part, "character.getParts(" .. tostring(index) .. ")", bind_part_name)
        else
            entry.error = trim_text(part, 180)
        end
        table.insert(trace.character_parts, entry)
    end
    local limit = tonumber(config.edit_region_trace_candidates) or 8
    for index, candidate in ipairs(candidates or {}) do
        if index > limit then
            break
        end
        table.insert(trace.candidates, probe_edit_region_source(candidate.obj, tostring(candidate.label), bind_part_name))
    end
    return trace
end

 
 
 
 

local function load_armor_variant_config(body_id)
    if not body_id or body_id == "" then
        return nil, "empty body id"
    end
    local path = "ArmorVariantManager/" .. tostring(body_id) .. ".json"
    local ok, data = pcall(function()
        return json.load_file(path)
    end)
    if ok and type(data) == "table" then
        return data, path
    end
    return nil, "failed to load " .. path .. ": " .. tostring(data)
end

local function get_armor_variant_manager_api()
    local ok_global, api = pcall(function()
        return _G and _G.NPCModelBridge_ArmorVariantManager
    end)
    if ok_global and type(api) == "table" then
        return api
    end
    return nil
end


local function collection_count(collection)
    if not collection then
        return nil
    end
    if type(collection) == "table" then
        return #collection
    end
    local ok_count, count = safe_call(collection, "get_Count")
    if ok_count and tonumber(count) then
        return tonumber(count)
    end
    local ok_len, len = safe_call(collection, "get_Length")
    if ok_len and tonumber(len) then
        return tonumber(len)
    end
    return nil
end

local function collection_item(collection, index)
    if not collection then
        return nil
    end
    if type(collection) == "table" then
        return collection[index + 1]
    end
    local ok_item, item = safe_call(collection, "get_Item", index)
    if ok_item then
        return item
    end
    return nil
end

local function is_mesh_component(component)
    if not component then
        return false
    end
    local ok_type, type_def = pcall(function()
        return component:get_type_definition()
    end)
    if ok_type and type_def then
        local ok_name, full_name = pcall(function()
            return type_def:get_full_name()
        end)
        return ok_name and full_name == "via.render.Mesh"
    end
    return false
end

local function collect_mesh_components_recursive(game_obj, limit)
    local meshes = {}
    local seen_meshes = {}
    local visited = {}
    local count = 0
    limit = tonumber(limit) or 128
    local mesh_type = get_runtime_type("via.render.Mesh")
    local function remember(mesh)
        if not mesh then
            return
        end
        local key = tostring(mesh)
        if seen_meshes[key] then
            return
        end
        seen_meshes[key] = true
        table.insert(meshes, mesh)
    end
    local function remember_all_mesh_components(actual)
        local ok_components, components = safe_call(actual, "get_Components")
        if ok_components and components then
            local total = collection_count(components)
            if total and total > 0 then
                for i = 0, total - 1 do
                    local component = collection_item(components, i)
                    if is_mesh_component(component) then
                        remember(component)
                    end
                end
            end
        end
        if mesh_type then
            local ok_mesh, mesh = safe_call(actual, "getComponent(System.Type)", mesh_type)
            if ok_mesh and mesh then
                remember(mesh)
            end
        end
    end
    local function visit(obj, depth)
        if not is_valid_managed_object(obj) or depth > 6 or count >= limit then
            return
        end
        local key = tostring(obj)
        if visited[key] then
            return
        end
        visited[key] = true
        count = count + 1
        local actual = get_game_object(obj) or obj
        remember_all_mesh_components(actual)
        local transform = get_transform(actual)
        if not transform then
            return
        end
        local ok_child, child = safe_call(transform, "get_Child")
        while ok_child and child and count < limit do
            local ok_obj, child_obj = safe_call(child, "get_GameObject")
            if ok_obj and child_obj then
                visit(child_obj, depth + 1)
            end
            ok_child, child = safe_call(child, "get_Next")
        end
    end
    visit(game_obj, 0)
    return meshes
end

local ARMOR_VARIANT_PART_SUFFIX_BY_INDEX = {
    [0] = "3",
    [1] = "2",
    [2] = "1",
    [3] = "5",
    [4] = "4",
    [5] = "6"
}

local function build_armor_variant_part_name(body_id, part_index)
    local suffix = ARMOR_VARIANT_PART_SUFFIX_BY_INDEX[tonumber(part_index)]
    if not suffix then
        return nil
    end
    local prefix = string.match(tostring(body_id or ""), "^(ch%d%d_%d%d%d_%d%d%d)")
    if not prefix then
        return nil
    end
    return prefix .. suffix
end

local function is_private_face_or_native_chain_name(name)
    local text = tostring(name or "")
    local prefix = string.sub(text, 1, 4)
    return prefix == "ch00" or prefix == "ch01" or prefix == "ch04"
end

local function count_material_matches_for_part(part_obj, part_data)
    local result = {
        mesh_count = 0,
        materials_checked = 0,
        material_matches = 0
    }
    if not part_obj or type(part_data) ~= "table" then
        return result
    end
    local meshes = collect_mesh_components_recursive(part_obj)
    result.mesh_count = #meshes
    if type(part_data.materials) ~= "table" then
        return result
    end
    for _, mesh in ipairs(meshes) do
        local ok_count, material_count = safe_call(mesh, "get_MaterialNum")
        local count = tonumber(material_count) or 0
        if ok_count and count > 0 then
            for material_index = 0, count - 1 do
                result.materials_checked = result.materials_checked + 1
                local ok_name, material_name = safe_call(mesh, "getMaterialName", material_index)
                if ok_name and material_name ~= nil and part_data.materials[tostring(material_name)] ~= nil then
                    result.material_matches = result.material_matches + 1
                end
            end
        end
    end
    return result
end

 
local function collect_armor_variant_part_candidates(character, root_obj, body_id, part_index, part_data, extra_roots)
    local candidates = {}
    local seen = {}
    local expected_name = build_armor_variant_part_name(body_id, part_index)
    local function add(obj, source)
        if not obj then
            return
        end
        local actual = get_game_object(obj) or obj
        if not actual then
            return
        end
        local key = tostring(actual)
        if seen[key] then
            return
        end
        seen[key] = true
        local name = get_game_object_name(actual)
        local match_counts = count_material_matches_for_part(actual, part_data)
        local exact_part_name = expected_name and lower_contains(name, expected_name) or false
        local prefix = string.sub(tostring(name or ""), 1, 4)
        local is_hunter_armor = prefix == "ch02" or prefix == "ch03"
        local blocked_private_chain = is_private_face_or_native_chain_name(name)
        local score = 0
        if exact_part_name then
            score = score + 1000
        elseif is_hunter_armor then
            score = score + 250
        elseif blocked_private_chain then
            score = score - 500
        end
        score = score + (match_counts.material_matches * 20) + match_counts.mesh_count
        if blocked_private_chain and match_counts.material_matches == 0 then
            score = score - 500
        end
        table.insert(candidates, {
            obj = actual,
            name = name,
            source = source,
            expected_name = expected_name or "",
            exact_part_name = exact_part_name,
            is_hunter_armor = is_hunter_armor,
            blocked_private_chain = blocked_private_chain,
            mesh_count = match_counts.mesh_count,
            materials_checked = match_counts.materials_checked,
            material_matches = match_counts.material_matches,
            score = score
        })
    end
    local ok_part, part = safe_call(character, "getParts", part_index)
    if ok_part and part then
        add(part, "character.getParts")
    end
    if root_obj then
        for _, obj in ipairs(collect_child_game_objects(root_obj)) do
            local actual = get_game_object(obj) or obj
            local name = get_game_object_name(actual)
            local prefix = string.sub(tostring(name or ""), 1, 4)
            if (expected_name and lower_contains(name, expected_name)) or prefix == "ch02" or prefix == "ch03" then
                add(actual, "root.armor")
            end
        end
    end
    if type(extra_roots) == "table" then
        for _, obj in ipairs(extra_roots) do
            add(obj, "event.pl_equip")
        end
    end
    return candidates
end

local function is_usable_armor_variant_candidate(candidate, part_data)
    if not candidate or candidate.mesh_count <= 0 then
        return false
    end
    if candidate.material_matches > 0 then
        return true
    end
    if type(part_data) == "table" and type(part_data.materials) == "table" and next(part_data.materials) ~= nil then
        return candidate.exact_part_name and not candidate.blocked_private_chain
    end
    return (candidate.exact_part_name or candidate.is_hunter_armor) and not candidate.blocked_private_chain
end

 
local function choose_armor_variant_part_for_index(character, root_obj, body_id, part_index, part_data, operation, extra_roots)
    local candidates = collect_armor_variant_part_candidates(character, root_obj, body_id, part_index, part_data, extra_roots)
    local best = nil
    for _, candidate in ipairs(candidates) do
        if is_usable_armor_variant_candidate(candidate, part_data) then
            if not best or candidate.score > best.score then
                best = candidate
            end
        end
    end
    if operation then
        if type(operation.part_candidate_trace) ~= "table" then
            operation.part_candidate_trace = {}
        end
        local trace = {}
        for _, candidate in ipairs(candidates) do
            table.insert(trace, {
                name = tostring(candidate.name or ""),
                source = tostring(candidate.source or ""),
                expected_name = tostring(candidate.expected_name or ""),
                exact_part_name = candidate.exact_part_name == true,
                is_hunter_armor = candidate.is_hunter_armor == true,
                blocked_private_chain = candidate.blocked_private_chain == true,
                mesh_count = candidate.mesh_count,
                materials_checked = candidate.materials_checked,
                material_matches = candidate.material_matches,
                score = candidate.score
            })
        end
        operation.part_candidate_trace[tostring(part_index)] = trace
        if best then
            operation.part_object_names[tostring(part_index)] = get_game_object_name(best.obj)
            operation.part_match_counts[tostring(part_index)] = best.material_matches
            operation.part_selection_sources[tostring(part_index)] = tostring(best.source or "")
            if best.material_matches > 0 then
                operation.armor_variant_carrier_strategy = "material_match"
            elseif operation.armor_variant_carrier_strategy == "" then
                operation.armor_variant_carrier_strategy = "exact_armor_part"
            end
        end
    end
    return best and best.obj or nil
end

 
 
 
 

local function merge_armor_variant_part_data(target_preset, source_preset)
    if type(source_preset) ~= "table" then
        return
    end
    for part_key, part_data in pairs(source_preset) do
        if type(part_data) == "table" then
            local target_part = target_preset[tostring(part_key)]
            if type(target_part) ~= "table" then
                target_part = {}
                target_preset[tostring(part_key)] = target_part
            end
            if part_data.mesh_enabled ~= nil then
                target_part.mesh_enabled = part_data.mesh_enabled == true
            end
            if type(part_data.materials) == "table" then
                if type(target_part.materials) ~= "table" then
                    target_part.materials = {}
                end
                for material_name, enabled in pairs(part_data.materials) do
                    target_part.materials[tostring(material_name)] = enabled == true
                end
            end
        end
    end
end

local function merge_armor_variant_global_hidden(target_preset, source_preset)
    if type(source_preset) ~= "table" then
        return
    end
    for part_key, part_data in pairs(source_preset) do
        if type(part_data) == "table" and type(part_data.materials) == "table" then
            local target_part = target_preset[tostring(part_key)]
            if type(target_part) ~= "table" then
                target_part = {}
                target_preset[tostring(part_key)] = target_part
            end
            if type(target_part.materials) ~= "table" then
                target_part.materials = {}
            end
            for material_name, enabled in pairs(part_data.materials) do
                if enabled == false then
                    target_part.materials[tostring(material_name)] = false
                end
            end
        end
    end
end

 
local function build_static_armor_variant_preset(avm_data)
    local preset = {}
    local used = { source = "static", default_preset = "", group_presets = {} }
    if type(avm_data) ~= "table" then
        return preset, used
    end
    if type(avm_data.presets) == "table" and avm_data.default_preset and type(avm_data.presets[avm_data.default_preset]) == "table" then
        merge_armor_variant_part_data(preset, avm_data.presets[avm_data.default_preset])
        used.default_preset = tostring(avm_data.default_preset)
    end
    if type(avm_data.groups) == "table" then
        for group_name, group_data in pairs(avm_data.groups) do
            if type(group_data) == "table"
                and group_data.is_global ~= true
                and group_data.default_preset
                and type(group_data.presets) == "table" then
                local group_preset = group_data.presets[group_data.default_preset]
                if type(group_preset) == "table" then
                    merge_armor_variant_part_data(preset, group_preset)
                    table.insert(used.group_presets, tostring(group_name) .. ":" .. tostring(group_data.default_preset))
                end
            end
        end
        for group_name, group_data in pairs(avm_data.groups) do
            if type(group_data) == "table"
                and group_data.is_global == true
                and group_data.default_preset
                and type(group_data.presets) == "table" then
                local group_preset = group_data.presets[group_data.default_preset]
                if type(group_preset) == "table" then
                    merge_armor_variant_global_hidden(preset, group_preset)
                    table.insert(used.group_presets, tostring(group_name) .. ":" .. tostring(group_data.default_preset))
                end
            end
        end
    end
    return preset, used
end

 
local function apply_builtin_armor_variant(character, target, body_id, avm_data, avm_source, options)
    local operation = {
        time = os.clock(),
        mode = "armor_variant_builtin",
        body_id = tostring(body_id or ""),
        target = tostring(target and (target.display_name or target.npc_id or target.body_id) or "target"),
        config_source = tostring(avm_source or ""),
        armor_variant_mode = tostring(config.armor_variant_mode or "static_defaults"),
        parts_checked = 0,
        parts_found = 0,
        parts_with_mesh = 0,
        mesh_components_checked = 0,
        mesh_requests = 0,
        mesh_changed = 0,
        mesh_set_failed = 0,
        materials_checked = 0,
        materials_matched = 0,
        materials_changed = 0,
        material_set_failed = 0,
        material_trace = {},
        part_object_names = {},
        part_match_counts = {},
        part_selection_sources = {},
        part_candidate_trace = {},
        armor_variant_carrier_strategy = "",
        status = "not attempted"
    }
    local trace_lookup = {}
    local trace_list = config.armor_variant_trace_materials
    if type(trace_list) ~= "table" then
        trace_list = default_config.armor_variant_trace_materials
    end
    if type(trace_list) == "table" then
        for _, material_name in pairs(trace_list) do
            trace_lookup[tostring(material_name)] = true
        end
    end
    local trace_limit = tonumber(config.armor_variant_trace_limit) or 64
    local function trace_material(part_index, part_obj, material_index, material_name, desired_material, ok_current, current_material, set_attempted, ok_set)
        if not material_name or not trace_lookup[tostring(material_name)] then
            return
        end
        if #operation.material_trace >= trace_limit then
            return
        end
        table.insert(operation.material_trace, {
            part_index = part_index,
            part_object = get_game_object_name(part_obj),
            material_index = material_index,
            material_name = tostring(material_name),
            desired = desired_material,
            current_ok = ok_current == true,
            current = current_material,
            set_attempted = set_attempted == true,
            set_ok = ok_set == true
        })
    end
    if operation.armor_variant_mode ~= "static_defaults" then
        operation.status = "builtin ArmorVariant mode unsupported: " .. operation.armor_variant_mode
        diagnostics.armor_variant = operation
        remember_operation(operation)
        return false, operation.status
    end
    stats.armor_variant_attempts = stats.armor_variant_attempts + 1
    options = options or {}
    local root_obj = options.root_obj or get_game_object(character) or character
    if not root_obj then
        operation.status = "no character game object"
        diagnostics.armor_variant = operation
        remember_operation(operation)
        return false, operation.status
    end
    local preset, used = build_static_armor_variant_preset(avm_data)
    operation.default_preset = tostring(used.default_preset or "")
    operation.group_presets = used.group_presets
    if not next(preset) then
        operation.status = "no ArmorVariant preset data"
        diagnostics.armor_variant = operation
        remember_operation(operation)
        return false, operation.status
    end
    for part_index = 0, 5 do
        local part_data = preset[tostring(part_index)]
        if type(part_data) == "table" then
            operation.parts_checked = operation.parts_checked + 1
            local part_obj = choose_armor_variant_part_for_index(character, root_obj, body_id, part_index, part_data, operation, options.extra_roots)
            if part_obj then
                operation.parts_found = operation.parts_found + 1
                local meshes = collect_mesh_components_recursive(part_obj)
                if #meshes > 0 then
                    operation.parts_with_mesh = operation.parts_with_mesh + 1
                    operation.mesh_components_checked = operation.mesh_components_checked + #meshes
                    if part_data.mesh_enabled ~= nil then
                        operation.mesh_requests = operation.mesh_requests + 1
                        local desired_mesh = part_data.mesh_enabled == true
                        local target_obj = get_game_object(part_obj) or part_obj
                        local ok_enabled, current_enabled = safe_call(target_obj, "get_Enabled")
                        if not ok_enabled or current_enabled ~= desired_mesh then
                            local ok_set = safe_call(target_obj, "set_Enabled", desired_mesh)
                            if ok_set then
                                operation.mesh_changed = operation.mesh_changed + 1
                            else
                                operation.mesh_set_failed = operation.mesh_set_failed + 1
                            end
                        end
                    end
                    if type(part_data.materials) == "table" then
                        for _, mesh in ipairs(meshes) do
                            local ok_count, material_count = safe_call(mesh, "get_MaterialNum")
                            local count = tonumber(material_count) or 0
                            if ok_count and count > 0 then
                                for material_index = 0, count - 1 do
                                    operation.materials_checked = operation.materials_checked + 1
                                    local ok_name, material_name = safe_call(mesh, "getMaterialName", material_index)
                                    local material_text = nil
                                    local desired_material = nil
                                    if ok_name and material_name ~= nil then
                                        material_text = tostring(material_name)
                                        desired_material = part_data.materials[material_text]
                                    end
                                    if desired_material ~= nil then
                                        desired_material = desired_material == true
                                        operation.materials_matched = operation.materials_matched + 1
                                        local ok_current, current_material = safe_call(mesh, "getMaterialsEnable", material_index)
                                        local set_attempted = false
                                        local ok_set = nil
                                        if not ok_current or current_material ~= desired_material then
                                            set_attempted = true
                                            ok_set = safe_call(mesh, "setMaterialsEnable", material_index, desired_material)
                                            if ok_set then
                                                operation.materials_changed = operation.materials_changed + 1
                                            else
                                                operation.material_set_failed = operation.material_set_failed + 1
                                            end
                                        end
                                        trace_material(part_index, part_obj, material_index, material_text, desired_material, ok_current, current_material, set_attempted, ok_set)
                                    elseif material_text and trace_lookup[material_text] then
                                        local ok_current, current_material = safe_call(mesh, "getMaterialsEnable", material_index)
                                        trace_material(part_index, part_obj, material_index, material_text, nil, ok_current, current_material, false, nil)
                                    end
                                end
                            end
                        end
                    end
                end
            end
        end
    end
    if operation.materials_matched > 0 then
        operation.status = "builtin static ArmorVariant applied parts=" .. tostring(operation.parts_with_mesh) .. " material_matches=" .. tostring(operation.materials_matched) .. " material_changes=" .. tostring(operation.materials_changed) .. " carrier=" .. tostring(operation.armor_variant_carrier_strategy or "")
        stats.armor_variant_ok = stats.armor_variant_ok + 1
        diagnostics.armor_variant = operation
        remember_operation(operation)
        return true, operation.status
    end
    if operation.parts_with_mesh > 0 then
        operation.status = "builtin static ArmorVariant found parts but no matching material; possible wrong carrier"
    else
        operation.status = "builtin static ArmorVariant found no matching part/material"
    end
    diagnostics.armor_variant = operation
    remember_operation(operation)
    return false, operation.status
end
 
 
local function apply_armor_variant_with_api(character, target, body_id, options)
    local operation = {
        time = os.clock(),
        mode = "armor_variant",
        body_id = tostring(body_id or ""),
        target = tostring(target and (target.display_name or target.npc_id or target.body_id) or "target"),
        status = "not attempted"
    }
    if config.auto_sync_armor_variant == false then
        operation.status = "disabled by config"
        diagnostics.armor_variant = operation
        return false, operation.status
    end
    local configured_avm_body_id = target and target.armor_variant_body_id or nil
    local avm_body_id = nil
    local configured_avm_id_empty = configured_avm_body_id == nil
    if type(configured_avm_body_id) == "string" then
        configured_avm_body_id = string.match(configured_avm_body_id, "^%s*(.-)%s*$") or ""
        configured_avm_id_empty = configured_avm_body_id == ""
        if string.lower(configured_avm_body_id) == "static" then
            operation.mode = "armor_variant_static_package"
            operation.status = "static package materials; AVM sync skipped"
            diagnostics.armor_variant = operation
            remember_operation(operation)
            return true, operation.status
        elseif configured_avm_body_id ~= "" then
            avm_body_id = configured_avm_body_id
        end
    elseif configured_avm_body_id ~= nil then
        avm_body_id = tostring(configured_avm_body_id)
        configured_avm_id_empty = avm_body_id == ""
    end

    if not avm_body_id or avm_body_id == "" then
        if target then
            avm_body_id = target.body_id or body_id or target.bone_system_body_id
        else
            avm_body_id = body_id
        end
        if configured_avm_id_empty and avm_body_id and avm_body_id ~= "" then
            operation.config_id_resolution = "empty ArmorVariant config id; using body_id: " .. tostring(avm_body_id)
        end
    end
    if not avm_body_id or avm_body_id == "" then
        operation.mode = "armor_variant_default_state"
        operation.status = "ArmorVariant config id unavailable; using default material state"
        diagnostics.armor_variant = operation
        remember_operation(operation)
        return true, operation.status
    end

    operation.body_id = tostring(avm_body_id)
    local avm_data, avm_source = load_armor_variant_config(operation.body_id)
    operation.config_source = tostring(avm_source or "")
    operation.config_loaded = type(avm_data) == "table"
    if not avm_data then
        operation.mode = "armor_variant_default_state"
        operation.status = "ArmorVariant config not found; using default material state: " .. tostring(avm_source)
        diagnostics.armor_variant = operation
        remember_operation(operation)
        return true, operation.status
    end
    if config.use_builtin_armor_variant_sync ~= false then
        return apply_builtin_armor_variant(character, target, operation.body_id, avm_data, avm_source, options)
    end
    if config.use_armor_variant_manager_api == false then
        operation.status = "ArmorVariantManager API disabled"
        diagnostics.armor_variant = operation
        remember_operation(operation)
        return false, operation.status
    end
    local api = get_armor_variant_manager_api()
    operation.api_present = type(api) == "table"
    operation.api_apply_body_to_character_type = api and type(api.apply_body_to_character) or "nil"
    if not api or type(api.apply_body_to_character) ~= "function" then
        operation.status = "ArmorVariantManager API unavailable"
        diagnostics.armor_variant = operation
        remember_operation(operation)
        return false, operation.status
    end
    stats.armor_variant_attempts = stats.armor_variant_attempts + 1
    local ok, applied, status = pcall(api.apply_body_to_character, operation.body_id, character, true)
    operation.api_call_ok = ok
    operation.api_applied = applied == true
    operation.api_status = trim_text(status, 300)
    if not ok then
        operation.status = "ArmorVariantManager API error: " .. trim_text(applied, 300)
        diagnostics.armor_variant = operation
        remember_operation(operation)
        return false, operation.status
    end
    if applied then
        operation.status = "ArmorVariantManager API " .. tostring(status or "applied")
        stats.armor_variant_ok = stats.armor_variant_ok + 1
        diagnostics.armor_variant = operation
        remember_operation(operation)
        return true, operation.status
    end
    operation.status = "ArmorVariantManager API " .. tostring(status or "not applied")
    diagnostics.armor_variant = operation
    remember_operation(operation)
    return false, operation.status
end

 
 
 
 

 
local function perform_stage(candidate, motion, custom_skeleton, target, bone_body_id, bone_data)
    local mode = tostring(config.mode or "probe")
    local operation = {
        time = os.clock(),
        mode = mode,
        target = tostring(target.display_name or target.npc_id or "target"),
        candidate_label = tostring(candidate.label),
        candidate_name = tostring(candidate.name),
        candidate_object = tostring(candidate.obj),
        bone_body_id = tostring(bone_body_id or ""),
        resource_created = false,
        resource_owner = mode == "api_fix_bone" and "BoneSystemNPCAPI.fix_bone" or "BSFN.lua",
        resource_precreate_skipped = mode == "api_fix_bone",
        holder_ready = false,
        write_holder_ok = false,
        set_holder_ok = false,
        apply_custom_joint_ok = false,
        status = "started"
    }

    local resource_path = resource_path_from_bone_data(bone_data)
    operation.desired_resource_path = tostring(resource_path or "")
    if not resource_path then
        operation.status = "missing FbxPath"
        remember_operation(operation)
        return false, operation.status
    end

    if mode == "api_fix_bone" then
        local api_bone_data, private_mode, face_route = make_target_bone_data(bone_data, target)
        operation.private_face_mode = private_mode
        operation.face_route = tostring(face_route)
        if type(api_bone_data) == "table" then
            operation.api_hide_face = tostring(api_bone_data.HideFace)
            operation.api_bind_face = tostring(api_bone_data.BindFace)
        end
        operation.api_fix_bone_type = type(API.fix_bone)
        if operation.api_fix_bone_type ~= "function" then
            operation.status = "API.fix_bone missing"
            remember_operation(operation)
            return false, operation.status
        end
        local ok_api, api_result = pcall(function()
            return API.fix_bone(candidate.obj, api_bone_data, nil)
        end)
        operation.api_fix_bone_ok = ok_api
        operation.api_fix_bone_result = trim_text(api_result, 500)
        if ok_api then
            local ok_post_holder, post_holder = call_any(custom_skeleton, "get_SkeletonResourceHandle")
            operation.post_holder_ready = ok_post_holder and post_holder ~= nil
            if operation.post_holder_ready then
                operation.post_holder_object = tostring(post_holder)
                operation.post_holder_address, operation.post_holder_address_raw = get_address_text(post_holder)
                local ok_post_path, post_path = call_any(post_holder, "get_ResourcePath")
                operation.post_resource_path = ok_post_path and tostring(post_path or "") or ""
            else
                operation.post_resource_path = ""
            end
        end
        if not ok_api then
            operation.status = "api_fix_bone failed"
            remember_operation(operation)
            return false, operation.status
        end
        operation.status = "api_fix_bone ok"
        remember_operation(operation)
        return true, operation.status
    end

    local ok_holder, holder = call_any(custom_skeleton, "get_SkeletonResourceHandle")
    if not ok_holder or not holder then
        operation.status = "no current SkeletonResourceHandle"
        operation.error = trim_text(holder, 500)
        remember_operation(operation)
        return false, operation.status
    end
    operation.holder_ready = true
    operation.holder_object = tostring(holder)
    operation.holder_address, operation.holder_address_raw = get_address_text(holder)

    local ok_add_ref, add_ref_result = call_any(holder, "add_ref")
    operation.holder_add_ref_ok = ok_add_ref
    operation.holder_add_ref_result = trim_text(add_ref_result, 200)

    local ok_current, current_path = call_any(holder, "get_ResourcePath")
    operation.current_resource_path = ok_current and tostring(current_path or "") or ""

    local ok_resource, resource = pcall(function()
        return sdk.create_resource("via.motion.SkeletonResource", resource_path)
    end)
    if not ok_resource or not resource then
        operation.status = "resource create failed"
        operation.error = trim_text(resource, 500)
        remember_operation(operation)
        return false, operation.status
    end
    retained_resources[resource_path] = resource
    operation.resource_created = true
    operation.resource_object = tostring(resource)
    operation.resource_address, operation.resource_address_raw = get_address_text(resource)

    if mode == "probe" then
        operation.status = "probe ok"
        remember_operation(operation)
        return true, operation.status
    end

    if mode == "write_holder" or mode == "set_holder" or mode == "native_direct" then
        if not operation.resource_address_raw then
            operation.status = "resource address missing"
            remember_operation(operation)
            return false, operation.status
        end
        local ok_write, write_result = call_any(holder, "write_qword", 7, operation.resource_address_raw)
        operation.write_holder_ok = ok_write
        operation.write_holder_result = trim_text(write_result, 500)
        if not ok_write then
            operation.status = "write_holder failed"
            remember_operation(operation)
            return false, operation.status
        end
    end

    if mode == "native_direct" then
        operation.motion_address, operation.motion_address_raw = get_address_text(motion)
        operation.custom_skeleton_address, operation.custom_skeleton_address_raw = get_address_text(custom_skeleton)
        operation.holder_address, operation.holder_address_raw = get_address_text(holder)
        operation.sdk_fix_bone_type = type(sdk.fix_bone)
        operation.default_value = bone_data.Default == true
        if operation.sdk_fix_bone_type ~= "function" then
            operation.status = "sdk.fix_bone missing"
            remember_operation(operation)
            return false, operation.status
        end
        if not operation.motion_address_raw or not operation.custom_skeleton_address_raw or not operation.holder_address_raw then
            operation.status = "native address missing"
            remember_operation(operation)
            return false, operation.status
        end
        local ok_native, native_result = pcall(function()
            return sdk.fix_bone(operation.motion_address_raw, operation.custom_skeleton_address_raw, operation.holder_address_raw, operation.default_value, 0)
        end)
        operation.native_direct_ok = ok_native
        operation.native_direct_result = trim_text(native_result, 500)
        if ok_native then
            local ok_apply, apply_result = call_any(custom_skeleton, "applyCustomJoint")
            operation.apply_custom_joint_ok = ok_apply
            operation.apply_custom_joint_result = trim_text(apply_result, 500)
            local ok_post_holder, post_holder = call_any(custom_skeleton, "get_SkeletonResourceHandle")
            if ok_post_holder and post_holder then
                local ok_post_path, post_path = call_any(post_holder, "get_ResourcePath")
                operation.post_resource_path = ok_post_path and tostring(post_path or "") or ""
            else
                operation.post_resource_path = ""
            end
        end
        if not ok_native then
            operation.status = "native_direct failed"
            remember_operation(operation)
            return false, operation.status
        end
    end

    if mode == "set_holder" then
        local ok_set, set_result = call_any(custom_skeleton, "set_SkeletonResourceHandle", holder)
        operation.set_holder_ok = ok_set
        operation.set_holder_result = trim_text(set_result, 500)
        if ok_set then
            local ok_apply, apply_result = call_any(custom_skeleton, "applyCustomJoint")
            operation.apply_custom_joint_ok = ok_apply
            operation.apply_custom_joint_result = trim_text(apply_result, 500)
            local ok_post_holder, post_holder = call_any(custom_skeleton, "get_SkeletonResourceHandle")
            if ok_post_holder and post_holder then
                local ok_post_path, post_path = call_any(post_holder, "get_ResourcePath")
                operation.post_resource_path = ok_post_path and tostring(post_path or "") or ""
            else
                operation.post_resource_path = ""
            end
        end
        if not ok_set then
            operation.status = "set_holder failed"
            remember_operation(operation)
            return false, operation.status
        end
    end

    operation.status = mode .. " ok"
    remember_operation(operation)
    return true, operation.status
end

 
 
 
 
local nonhuman_family = (function()
    local helper = {}
    local enum_values
    local metrics = { inspected = 0, eligible = 0, skipped = 0, recent = {} }
    performance.nonhuman_family = metrics

    local function read(object, method, ...)
        if not object then return nil end
        local ok, value = safe_call(object, method, ...)
        if ok then return value end
        return nil
    end

    local function address(object)
        if not object then return nil end
        local ok, value = pcall(function() return object:get_address() end)
        if ok and type(value) == "number" and value > 0 and value % 1 == 0 then return value end
        return nil
    end

     
    local function constants()
        if enum_values ~= nil then return enum_values end
        local ok, values = pcall(function()
            local function value(kind, name)
                local definition = assert(safe_sdk_type(kind), "enum type unavailable")
                local field = assert(definition:get_field(name), "enum field unavailable")
                local result = field:get_data(nil)
                assert(type(result) == "number" and result == result and result % 1 == 0, "invalid enum value")
                return result
            end
            return {
                species = value("app.NpcDef.SPECIES", "RYUJIN"),
                normal = value("app.NpcDef.SKELETON_TYPE", "RYUJIN_NML"),
                small = value("app.NpcDef.SKELETON_TYPE", "RYUJIN_SML")
            }
        end)
        enum_values = ok and values or false
        return enum_values
    end

    local function joint(transform, name)
        local object = read(transform, "getJointByName", name)
        if object and read(object, "get_Valid") == true then return object end
        return nil
    end

     
    local function source_legs(transform, profile)
        local chain = profile == "RYUJIN_NML" and { "Thigh", "Knee", "Shin", "Foot", "Toe" }
            or { "Thigh", "Shin", "Foot", "Toe" }
        for _, side in ipairs({ "L", "R" }) do
            if joint(transform, side .. "_Instep") then return false end
            if profile == "RYUJIN_SML" and joint(transform, side .. "_Knee") then return false end
            local previous
            for _, suffix in ipairs(chain) do
                local name = side .. "_" .. suffix
                local current = joint(transform, name)
                if not current or previous and read(read(current, "get_Parent"), "get_Name") ~= previous then
                    return false
                end
                previous = name
            end
        end
        return true
    end

     
    local function source_fingers(transform)
        for _, side in ipairs({ "L", "R" }) do
            local previous = side .. "_Palm"
            if not joint(transform, previous) then return false end
            for index = 1, 3 do
                if joint(transform, side .. "_PinkyF" .. index) then return false end
                local name = side .. "_RingF" .. index
                local current = joint(transform, name)
                if not current or read(read(current, "get_Parent"), "get_Name") ~= previous then return false end
                previous = name
            end
        end
        return true
    end

    function helper.classify(candidate, state, entry)
         
        if not same_runtime_object(read(entry.character, "get_GameObject"), candidate.obj) then
            return { profile = "unsupported", leg_ok = false, fingers_ok = false, reason = "not the NPC root" }
        end
        local root_id, motion_id, skeleton_id = address(candidate.obj), address(state.motion), address(state.custom_skeleton)
        if not root_id or not motion_id or not skeleton_id then
            return { profile = "unsupported", leg_ok = false, fingers_ok = false, reason = "native identity unavailable" }
        end
        local cached = entry.nonhuman_family
        if cached and cached.root == root_id and cached.motion == motion_id and cached.skeleton == skeleton_id
            and cached.generation == scene_generation then return cached end
         
         
        local result = { profile = "unsupported", leg_ok = false, fingers_ok = false, reason = "native tags unavailable",
            root = root_id, motion = motion_id, skeleton = skeleton_id, generation = scene_generation }
        entry.nonhuman_family = result
        metrics.inspected = metrics.inspected + 1
        local values = constants()
        local context = values and read(entry.character, "get_NpcContext")
        if context then
            local species_ok, species = safe_field(context, "Species")
            local skeleton_ok, skeleton = safe_field(context, "SkeletonType")
            if species_ok and type(species) == "number" then result.species = species end
            if skeleton_ok and type(skeleton) == "number" then result.skeleton_type = skeleton end
            if species_ok and skeleton_ok and species == values.species
                and (skeleton == values.normal or skeleton == values.small) then
                result.profile = skeleton == values.normal and "RYUJIN_NML" or "RYUJIN_SML"
                result.ik_asset = skeleton == values.normal and "NpcIkLeg_Ryujin.ikleg2" or "NpcIkLeg_RyujinSmall.ikleg2"
                local transform = get_transform(candidate.obj)
                if transform and read(state.motion, "get_JointsConstructed") == true then
                    result.leg_ok = source_legs(transform, result.profile)
                    result.fingers_ok = source_fingers(transform)
                    result.reason = "native tags and original joint topology checked"
                else
                    result.reason = "original joints unavailable; no speculative correction"
                end
                metrics.eligible = metrics.eligible + 1
            else
                result.reason = "species/skeleton family not supported"
            end
        end
        if not result.leg_ok and not result.fingers_ok then metrics.skipped = metrics.skipped + 1 end
         
        local row = { npc_id = tostring(entry.npc_id), generation = scene_generation }
        for key, value in pairs(result) do row[key] = value end
        metrics.recent[#metrics.recent + 1] = row
        if #metrics.recent > 16 then table.remove(metrics.recent, 1) end
        bs_log("[NonhumanFamily] " .. row.npc_id .. " " .. result.profile .. " " .. result.reason)
        return result
    end

    return helper
end)()

 
 
 
 
 
local nonhuman_retry = (function()
    local helper = {}

    function helper.ready(plan, now)
        return plan ~= nil and config.enabled and not scene_transition.active
            and not normal_runtime_menu_suspended and now >= plan.next_check
    end

     
    local function slow_interval()
        local value = tonumber(config.inspect_interval) or 1.0
        if value ~= value or value == math.huge or value == -math.huge then value = 1.0 end
        return math.max(0.5, value)
    end

    function helper.defer(plan, state, detail, now, limit, checks)
        local slow = checks >= limit
        plan.next_check = now + (slow and slow_interval() or 0.05)
        state.status, state.detail = "pending", tostring(detail or "not ready")
        state.checks, state.retry_mode = plan.checks, slow and "throttled" or "initial"
    end
    return helper
end)()

 
 
 
 
 
 
local nonhuman_resources = (function()
    local exports, load_error = {}, nil
    return function(kind, root, component, count)
        if load_error then error(load_error) end
        if not exports[kind] then
            local ok, result = pcall(function()
                assert(_VERSION == "Lua 5.4", "Lua 5.4 required")
                local path = "reframework/plugins/BSFNForefoot.dll"
                local probe = assert(package.loadlib(path, "bsfn_resource_probe"))
                assert(probe(0x42534638, 0, 0, 0, 0, 0, 0) == 1, "native resource ABI refused")
                return assert(package.loadlib(path, "bsfn_resource_" .. kind))
            end)
            if not ok then load_error = tostring(result); error(load_error) end
            exports[kind] = result
        end
        return exports[kind](0x42534638, root, component, count or 0, 0, 0, 0)
    end
end)()

local nonhuman_ik = (function()
    local helper = {}
    local destination = "Motion/NPC/Decorate/IkLeg/NpcIkLeg_Default.ikleg2"
    local max_checks, max_setup_checks, retry_interval = 12, 4, 0.05
    local metrics = { prepared = 0, applied = 0, skipped = 0, errors = 0, checks = 0, assigned = 0, recent = {} }
    performance.nonhuman_ik = metrics

    local function normalized(path)
        return tostring(path or ""):gsub("\\", "/"):lower():gsub("^@", ""):gsub("%.%d+$", "")
    end

    local function read(object, method, ...)
        if not object then return nil end
        local ok, value = safe_call(object, method, ...)
        if ok then return value end
        return nil
    end

    local function resource_path(component, method)
        return read(read(component, method), "get_ResourcePath")
    end

     
     
    local function native_address(object)
        if not object then return nil end
        local ok, value = pcall(function() return object:get_address() end)
        if ok and type(value) == "number" and value > 0 and value % 1 == 0 then return value end
        return nil
    end

     
    local function record(entry, profile, status, detail)
        entry.nonhuman_ik_pending = nil
        entry.nonhuman_ik = { profile = profile, status = status, detail = tostring(detail or "") }
        local item = {
            generation = scene_generation, npc_id = tostring(entry.npc_id or ""),
            profile = profile, status = status, detail = tostring(detail or "")
        }
        metrics.recent[#metrics.recent + 1] = item
        if #metrics.recent > 16 then table.remove(metrics.recent, 1) end
        if status == "applied" then metrics.applied = metrics.applied + 1
        elseif status == "error" then metrics.errors = metrics.errors + 1
        else metrics.skipped = metrics.skipped + 1 end
        bs_log("[NonhumanIK] " .. item.npc_id .. " " .. status .. " " .. item.detail)
    end

     
    function helper.prepare(candidate, state, entry, bone_data)
        if not state or not entry or entry.nonhuman_ik or not config.enabled
            or config.mode ~= "api_fix_bone" or config.auto_apply_bone == false
            or scene_transition.active or normal_runtime_menu_suspended
            or entry.scene_generation ~= scene_generation or bone_data.FixBone == false then
            return nil
        end
        local source_path = normalized(state.resource_path)
        local family = nonhuman_family.classify(candidate, state, entry)
        local profile, expected = family.profile, family.ik_asset
        if not expected then return nil end
        if not family.leg_ok then
            record(entry, profile, "skipped", "native tag/source leg topology mismatch")
            return nil
        end
        if not same_runtime_object(read(entry.character, "get_GameObject"), candidate.obj) then
            record(entry, profile, "skipped", "IK candidate is not the registered NPC root")
            return nil
        end
        local desired = resource_path_from_bone_data(bone_data)
        if not desired or normalized(desired) == source_path then
            record(entry, profile, "skipped", "no distinct target skeleton")
            return nil
        end
        local component = get_component(candidate.obj, "via.motion.IkLeg2")
        local path = resource_path(component, "get_IkLeg2Asset")
        if not path then
            record(entry, profile, "skipped", "native IkLeg2 asset unavailable")
            return nil
        end
        if normalized(path) == normalized(destination) then
            record(entry, profile, "skipped", "already uses human IK; check old Core overrides")
            return nil
        end
        local expected_path = "@Motion/NPC/Decorate/IkLeg/" .. expected
        if normalized(path) ~= normalized(expected_path) then
            record(entry, profile, "skipped", "unexpected native IK: " .. tostring(path))
            return nil
        end
        local candidate_address = native_address(candidate.obj)
        local motion_address = native_address(state.motion)
        local skeleton_address = native_address(state.custom_skeleton)
        local component_address = native_address(component)
        if not candidate_address or not motion_address or not skeleton_address or not component_address then
            record(entry, profile, "skipped", "native component address unavailable; no display-text fallback")
            return nil
        end
        metrics.prepared = metrics.prepared + 1
         
        return {
            profile = profile, candidate = candidate_address,
            component = component_address, motion = motion_address,
            skeleton = skeleton_address, desired = normalized(desired),
            original_ik_path = normalized(path), generation = scene_generation,
            dictionary = dictionary_generation, checks = 0, next_check = 0
        }
    end

     
    local function human_leg_chain(candidate)
        local transform = get_transform(candidate)
        if not transform then return false, "missing current Transform" end
        for _, side in ipairs({ "L", "R" }) do
            local previous
            for _, suffix in ipairs({ "Thigh", "Knee", "Shin", "Foot", "Instep", "Toe" }) do
                local name = side .. "_" .. suffix
                local joint = read(transform, "getJointByName", name)
                if not joint or read(joint, "get_Valid") ~= true then return false, "missing joint " .. name end
                if previous and read(read(joint, "get_Parent"), "get_Name") ~= previous then
                    return false, "unexpected parent " .. name
                end
                previous = name
            end
        end
        for _, name in ipairs({ "COG", "Ground_Angle" }) do
            local joint = read(transform, "getJointByName", name)
            if not joint or read(joint, "get_Valid") ~= true then return false, "missing IK joint " .. name end
        end
        return true
    end

     
    function helper.finish(plan, bone_ok, entry)
        if not plan or not bone_ok then return end
        entry.nonhuman_ik_pending = plan
        entry.nonhuman_ik = { profile = plan.profile, status = "pending", detail = "waiting for native skeleton commit" }
    end

     
    function helper.update(entry, now)
        local plan = entry.nonhuman_ik_pending
        if not nonhuman_retry.ready(plan, now) then return end
        local profile = plan.profile
        plan.checks = plan.checks + 1
        if plan.assigned then plan.setup_checks = (plan.setup_checks or 0) + 1 end
        metrics.checks = metrics.checks + 1
        plan.next_check = now + retry_interval
        local ok, status, detail = pcall(function()
            if not config.enabled or scene_transition.active or normal_runtime_menu_suspended
                or config.auto_apply_bone == false or config.mode ~= "api_fix_bone"
                or scene_generation ~= plan.generation or entry.scene_generation ~= plan.generation
                or dictionary_generation ~= plan.dictionary or entry.player_character_rejected
                or registered[tostring(entry.character)] ~= entry then
                return "skipped", "lifecycle/configuration changed before IK commit"
            end
            local recent_window = tonumber(config.readiness_recent_seen_window) or 0.5
            if now - entry.last_seen > recent_window then
                return "pending", "NPC no longer recently updated; no IK write"
            end
            local candidate = read(entry.character, "get_GameObject")
            if not is_valid_managed_object(candidate) then
                return "skipped", "current root is unavailable or invalid"
            end
            local current_address = native_address(candidate)
            if current_address ~= plan.candidate then
                return "skipped", "native root changed: expected=" .. tostring(plan.candidate)
                    .. "; current=" .. tostring(current_address)
            end
            local motion = get_component(candidate, "via.motion.Motion")
            local skeleton = get_component(candidate, "via.motion.CustomSkeleton")
            local component = get_component(candidate, "via.motion.IkLeg2")
            if not motion or not skeleton or not component
                or native_address(motion) ~= plan.motion
                or native_address(skeleton) ~= plan.skeleton
                or native_address(component) ~= plan.component
                or not same_runtime_object(read(motion, "get_GameObject"), candidate)
                or not same_runtime_object(read(skeleton, "get_GameObject"), candidate)
                or not same_runtime_object(read(component, "get_GameObject"), candidate) then
                return "skipped", "candidate/component identity changed"
            end
            if normalized(resource_path(skeleton, "get_SkeletonResourceHandle")) ~= plan.desired then
                return "skipped", "target skeleton path not applied"
            end
            local expected_ik = plan.assigned and normalized(destination) or plan.original_ik_path
            if normalized(resource_path(component, "get_IkLeg2Asset")) ~= expected_ik then
                return "skipped", "native IK changed during bone application"
            end
            if read(motion, "get_JointsConstructed") ~= true then return "pending", "target joints not constructed" end
            local setup_ready = plan.assigned and read(component, "get_Setuped") == true
            if plan.assigned and not setup_ready then
                return "pending", "asset assigned; waiting for native IK setup"
            end
            local chain_ok, chain_error = human_leg_chain(candidate)
            if not chain_ok then
                return plan.assigned and "skipped" or "pending", chain_error
            end
            if plan.assigned then
                if setup_ready then
                    return "applied", "native_setup=true; checks=" .. plan.checks
                end
                return "pending", "asset assigned; waiting for native IK setup"
            end
             
            local result = nonhuman_resources("ik", plan.candidate, plan.component)
            if result == 2 then return "pending", "native Scene lock busy; throttled retry" end
            assert(result == 0, "native IK resource guard=" .. tostring(result))
            plan.assigned = true
            metrics.assigned = metrics.assigned + 1
            assert(normalized(resource_path(component, "get_IkLeg2Asset")) == normalized(destination), "IK setter readback mismatch")
            if read(component, "get_Setuped") == true then
                return "applied", "human chain verified; native_setup=true; checks=" .. plan.checks
            end
            return "pending", "asset assigned; waiting for native IK setup"
        end)
        if not ok then detail, status = tostring(status), "error" end
        if status == "pending" then
            nonhuman_retry.defer(plan, entry.nonhuman_ik, detail, now,
                plan.assigned and max_setup_checks or max_checks,
                plan.assigned and (plan.setup_checks or 0) or plan.checks)
            return
        end
        record(entry, profile, status, detail)
    end

    return helper
end)()

 
 
 
 
local nonhuman_fingers = (function()
    local helper = {}
    local destination = "BoneSystemForNPC/Constraints/WyverianPinky_DSG.jcns"
    local max_checks, retry_interval, max_layers = 12, 0.05, 16
    local metrics = { prepared = 0, applied = 0, skipped = 0, errors = 0, checks = 0, recent = {} }
    performance.nonhuman_fingers = metrics

    local function normalized(path)
        return tostring(path or ""):gsub("\\", "/"):lower():gsub("^@", ""):gsub("%.%d+$", "")
    end

    local function read(object, method, ...)
        if not object then return nil end
        local ok, value = safe_call(object, method, ...)
        if ok then return value end
        return nil
    end

    local function address(object)
        if not object then return nil end
        local ok, value = pcall(function() return object:get_address() end)
        if ok and type(value) == "number" and value > 0 and value % 1 == 0 then return value end
        return nil
    end

    local function path_of(object, method)
        return normalized(read(read(object, method), "get_ResourcePath"))
    end

    local function record(entry, status, detail)
        entry.nonhuman_fingers_pending = nil
        entry.nonhuman_fingers = { status = status, detail = tostring(detail or "") }
        metrics.recent[#metrics.recent + 1] = {
            generation = scene_generation, npc_id = entry.npc_id, status = status,
            detail = tostring(detail or "")
        }
        if #metrics.recent > 16 then table.remove(metrics.recent, 1) end
        if status == "applied" then metrics.applied = metrics.applied + 1
        elseif status == "error" then metrics.errors = metrics.errors + 1
        else metrics.skipped = metrics.skipped + 1 end
        bs_log("[NonhumanFingers] " .. tostring(entry.npc_id) .. " " .. status .. " " .. tostring(detail))
    end

     
    function helper.prepare(candidate, state, entry, bone_data)
        if not state or not entry or entry.nonhuman_fingers or not config.enabled
            or config.mode ~= "api_fix_bone" or config.auto_apply_bone == false
            or scene_transition.active or normal_runtime_menu_suspended
            or entry.scene_generation ~= scene_generation or bone_data.FixBone == false then return nil end
        local family = nonhuman_family.classify(candidate, state, entry)
        if not family.ik_asset then return nil end
        if not family.fingers_ok then
            record(entry, "skipped", "native four-finger topology not verified")
            return nil
        end
        local desired = resource_path_from_bone_data(bone_data)
        if not desired or normalized(desired) == normalized(state.resource_path) then return nil end
        if not same_runtime_object(read(entry.character, "get_GameObject"), candidate.obj) then
            record(entry, "skipped", "candidate is not the registered NPC root")
            return nil
        end
        local component = get_component(candidate.obj, "via.motion.JointConstraints")
        local root, motion, skeleton, constraints = address(candidate.obj), address(state.motion),
            address(state.custom_skeleton), address(component)
        if not root or not motion or not skeleton or not constraints then
            record(entry, "skipped", "native component identity unavailable")
            return nil
        end
        if not same_runtime_object(read(component, "get_GameObject"), candidate.obj) then
            record(entry, "skipped", "constraints owner mismatch")
            return nil
        end
        metrics.prepared = metrics.prepared + 1
        return { root = root, motion = motion, skeleton = skeleton, constraints = constraints,
            desired = normalized(desired), profile = family.profile,
            generation = scene_generation, dictionary = dictionary_generation, checks = 0, next_check = 0 }
    end

    function helper.finish(plan, bone_ok, entry)
        if not plan or not bone_ok then return end
        entry.nonhuman_fingers_pending = plan
        entry.nonhuman_fingers = { status = "pending", detail = "waiting for target finger chain" }
    end

     
    local function valid_bind_rotation(rotation)
        if not rotation then return false end
        local ok, result = pcall(function()
            local x, y, z, w = rotation.x, rotation.y, rotation.z, rotation.w
            if type(x) ~= "number" or type(y) ~= "number" or type(z) ~= "number" or type(w) ~= "number" then return false end
            local norm = x * x + y * y + z * z + w * w
             
            return norm == norm and math.abs(norm - 1) < 0.001
        end)
        return ok and result == true
    end

    local function finger_chain(root)
        local transform = get_transform(root)
        if not transform then return false, "missing transform" end
        for _, side in ipairs({ "L", "R" }) do
            local palm = read(transform, "getJointByName", side .. "_Palm")
            if not palm or read(palm, "get_Valid") ~= true then return false, "missing palm " .. side end
            for _, finger in ipairs({ "RingF", "PinkyF" }) do
                local previous = side .. "_Palm"
                for index = 1, 3 do
                    local name = side .. "_" .. finger .. index
                    local joint = read(transform, "getJointByName", name)
                    if not joint or read(joint, "get_Valid") ~= true then return false, "missing joint " .. name end
                    if read(read(joint, "get_Parent"), "get_Name") ~= previous then
                        return false, "unexpected parent " .. name
                    end
                    if not valid_bind_rotation(read(joint, "get_BaseLocalRotation")) then
                        return false, "invalid base rotation " .. name
                    end
                    previous = name
                end
            end
        end
        return true
    end

     
    local function append_layer(component, plan)
        local count = read(component, "getLayerCount")
        assert(type(count) == "number" and count >= 1 and count < max_layers and count % 1 == 0, "invalid layer count")
        for index = 0, count - 1 do
            local layer = assert(read(component, "getLayer", index), "original layer unavailable")
            local path = path_of(layer, "get_JointConstraintsAsset")
            if path == normalized(destination) then return "applied", "already attached; no additional layer" end
        end
        local result = nonhuman_resources("fingers", plan.root, plan.constraints, count)
        if result == 2 then return "pending", "native Scene lock busy; throttled retry" end
        assert(result == 0, "native constraint resource guard=" .. tostring(result))
        return "applied", "native constraint layer attached; index=" .. count
    end

    function helper.update(entry, now)
        local plan = entry.nonhuman_fingers_pending
        if not nonhuman_retry.ready(plan, now) then return end
        plan.checks = plan.checks + 1
        plan.next_check = now + retry_interval
        metrics.checks = metrics.checks + 1
        local ok, status, detail = pcall(function()
            if not config.enabled or config.mode ~= "api_fix_bone" or config.auto_apply_bone == false
                or scene_transition.active or normal_runtime_menu_suspended or entry.player_character_rejected
                or scene_generation ~= plan.generation or entry.scene_generation ~= plan.generation
                or dictionary_generation ~= plan.dictionary or registered[tostring(entry.character)] ~= entry then
                return "skipped", "lifecycle/configuration changed"
            end
            if now - entry.last_seen > (tonumber(config.readiness_recent_seen_window) or 0.5) then
                return "pending", "NPC no longer recently updated"
            end
            local root = read(entry.character, "get_GameObject")
            if not is_valid_managed_object(root) or address(root) ~= plan.root then return "skipped", "root identity changed" end
            local motion = get_component(root, "via.motion.Motion")
            local skeleton = get_component(root, "via.motion.CustomSkeleton")
            local component = get_component(root, "via.motion.JointConstraints")
            if address(motion) ~= plan.motion or address(skeleton) ~= plan.skeleton
                or address(component) ~= plan.constraints
                or not same_runtime_object(read(motion, "get_GameObject"), root)
                or not same_runtime_object(read(skeleton, "get_GameObject"), root)
                or not same_runtime_object(read(component, "get_GameObject"), root) then
                return "skipped", "component identity/owner changed"
            end
            if path_of(skeleton, "get_SkeletonResourceHandle") ~= plan.desired then
                return "skipped", "target skeleton changed"
            end
            if read(motion, "get_JointsConstructed") ~= true then return "pending", "joints not constructed" end
            local valid, reason = finger_chain(root)
            if not valid then return "pending", reason end
            local status, detail = append_layer(component, plan)
            return status, detail .. "; expression_lod=" .. tostring(read(motion, "get_ExpressionLOD"))
        end)
        if not ok then detail, status = tostring(status), "error" end
        if status == "pending" then
            nonhuman_retry.defer(plan, entry.nonhuman_fingers, detail, now, max_checks, plan.checks)
            return
        end
        record(entry, status, detail)
    end

    return helper
end)()

 
 
 
 
 
local nonhuman_forefoot = (function()
    local helper = {}
     
    local max_checks, interval = 20, 0.05
    local native_apply, native_error, native_inspect
    local metrics = { prepared = 0, applied = 0, skipped = 0, errors = 0,
        checks = 0, native_calls = 0, recent = {}, lifecycle = "initial_apply_only" }
    performance.nonhuman_forefoot = metrics

    local function read(object, method, ...)
        if not object then return nil end
        local ok, value = safe_call(object, method, ...)
        if ok then return value end
        return nil
    end

    local function address(object)
        if not object then return nil end
        local ok, value = pcall(function() return math.tointeger(object:get_address()) end)
        if ok and value and value > 0 then return value end
        return nil
    end

    local function normalized(path)
        return tostring(path or ""):gsub("\\", "/"):lower():gsub("^@", ""):gsub("%.%d+$", "")
    end

    local function path_of(object, method)
        return normalized(read(read(object, method), "get_ResourcePath"))
    end

    local function record(entry, status, detail)
        entry.nonhuman_forefoot_pending = nil
        entry.nonhuman_forefoot = { status = status, detail = tostring(detail or "") }
        metrics.recent[#metrics.recent + 1] = { generation = scene_generation,
            npc_id = entry.npc_id, status = status, detail = tostring(detail or "") }
        if #metrics.recent > 16 then table.remove(metrics.recent, 1) end
        if status == "applied" then metrics.applied = metrics.applied + 1
        elseif status == "error" then metrics.errors = metrics.errors + 1
        else metrics.skipped = metrics.skipped + 1 end
        bs_log("[NonhumanForefoot] " .. tostring(entry.npc_id) .. " " .. status .. " " .. tostring(detail))
    end

    local function get_native()
        if native_apply then return native_apply end
        if native_error then return nil, native_error end
        native_error = "native helper unavailable"
        local ok, result = pcall(function()
            assert(_VERSION == "Lua 5.4", "Lua 5.4 required")
            local path = "reframework/plugins/BSFNForefoot.dll"
            local probe = assert(package.loadlib(path, "bsfn_forefoot_probe"))
            assert(probe(0x42534638, 0, 0, 0, 0, 0, 0) == 8, "native argument ABI refused")
            return assert(package.loadlib(path, "bsfn_forefoot_apply"))
        end)
        if not ok then native_error = tostring(result); return nil, native_error end
        native_apply, native_error = result, nil
        return native_apply
    end

     
    function helper.prepare(candidate, state, entry, bone_data, body_id)
        if not state or not entry or entry.nonhuman_forefoot or not config.enabled
            or config.mode ~= "api_fix_bone" or config.auto_apply_bone == false
            or scene_transition.active or normal_runtime_menu_suspended
            or entry.scene_generation ~= scene_generation or bone_data.FixBone == false then return nil end
        local family = nonhuman_family.classify(candidate, state, entry)
        if not family.ik_asset or not family.leg_ok then return nil end
        local desired = resource_path_from_bone_data(bone_data)
        if not desired or normalized(desired) == normalized(state.resource_path) then return nil end
        if not same_runtime_object(read(entry.character, "get_GameObject"), candidate.obj) then return nil end
        local root, motion, skeleton = address(candidate.obj), address(state.motion), address(state.custom_skeleton)
        if not root or not motion or not skeleton or type(body_id) ~= "string" or body_id == "" then return nil end
        metrics.prepared = metrics.prepared + 1
        return { root = root, motion = motion, skeleton = skeleton, body_id = body_id,
            desired = normalized(desired), profile = family.profile, generation = scene_generation,
            dictionary = dictionary_generation, checks = 0, next_check = 0 }
    end

    function helper.finish(plan, bone_ok, entry)
        if not plan or not bone_ok then return end
        entry.nonhuman_forefoot_pending = plan
        entry.nonhuman_forefoot = { status = "pending", detail = "waiting for own BODY binding" }
    end

     
    local function current_body(root_transform, body_id)
        local transform = read(root_transform, "get_Child")
        local found, seen = nil, {}
        for _ = 1, 32 do
            if not transform then return found end
            local key = address(transform)
            if not key or seen[key] then return nil end
            seen[key] = true
            local object = read(transform, "get_GameObject")
            if object and get_game_object_name(object) == body_id then
                if found then return nil end
                found = { object = object, transform = transform }
            end
            transform = read(transform, "get_Next")
        end
        return nil
    end

     
     
     
    local function body_components(object)
        local custom = get_component(object, "via.motion.CustomSkeleton")
        if custom then
            return "skipped", "BODY independent skeleton rebuild ordering not verified"
        end
        local motion = get_component(object, "via.motion.Motion")
        if motion then
            if read(motion, "get_JointsConstructed") ~= true then
                return "pending", "BODY joints not constructed"
            end
            local active = read(motion, "getActiveMotionBankCount")
            local dynamic = read(motion, "getDynamicMotionBankCount")
            if active ~= 0 or dynamic ~= 0 then
                return "skipped", "BODY authored Motion ordering not verified"
            end
        end
        local constraints = get_component(object, "via.motion.JointConstraints")
        if not constraints then return nil end
        if not native_inspect then
            native_inspect = assert(package.loadlib("reframework/plugins/BSFNForefoot.dll", "bsfn_forefoot_constraint"))
        end
        local count = read(constraints, "getLayerCount")
        if type(count) ~= "number" or count % 1 ~= 0 or count < 0 or count > 16 then
            return "skipped", "BODY constraint layer count unavailable"
        end
        local unchecked_skin, empty_layers = false, 0
        for index = 0, count - 1 do
            local layer = read(constraints, "getLayer", index)
            if not layer then return "pending", "BODY constraint layer not ready" end
            local pointer = address(layer)
            if not pointer then return "skipped", "BODY constraint identity unavailable" end
            local result = native_inspect(0x42534638, pointer, 0, 0, 0, 0, 0)
            if result == 2 then return "pending", "BODY constraint resource/Scene not ready" end
            if result == 30 then return "skipped", "BODY constraint writes foot; ordering not verified" end
             
            if result ~= 0 and result ~= 33 and result ~= 34 then return "skipped", "BODY constraint format not verified; native=" .. tostring(result) end
            if result == 33 then unchecked_skin = true end
            if result == 34 then empty_layers = empty_layers + 1 end
        end
        return nil, nil, unchecked_skin, empty_layers
    end

    function helper.update(entry, now)
        local plan = entry.nonhuman_forefoot_pending
        if not nonhuman_retry.ready(plan, now) then return end
        plan.checks, plan.next_check = plan.checks + 1, now + interval
        metrics.checks = metrics.checks + 1
        local ok, status, detail = pcall(function()
            if not config.enabled or config.mode ~= "api_fix_bone" or config.auto_apply_bone == false
                or scene_transition.active or normal_runtime_menu_suspended or entry.player_character_rejected
                or scene_generation ~= plan.generation or entry.scene_generation ~= plan.generation
                or dictionary_generation ~= plan.dictionary or registered[tostring(entry.character)] ~= entry then
                return "skipped", "lifecycle/configuration changed"
            end
            if now - entry.last_seen > (tonumber(config.readiness_recent_seen_window) or 0.5) then
                return "pending", "NPC no longer recently updated"
            end
            if entry.nonhuman_ik_pending then return "pending", "waiting for target skeleton/IK" end
            if entry.nonhuman_ik and entry.nonhuman_ik.status == "error" then
                return "skipped", "IK application failed; no automatic write retry"
            end
            local root = read(entry.character, "get_GameObject")
            if not is_valid_managed_object(root) or address(root) ~= plan.root then return "skipped", "root changed" end
            local motion, skeleton = get_component(root, "via.motion.Motion"), get_component(root, "via.motion.CustomSkeleton")
            if address(motion) ~= plan.motion or address(skeleton) ~= plan.skeleton
                or path_of(skeleton, "get_SkeletonResourceHandle") ~= plan.desired then return "skipped", "root skeleton changed" end
            if read(motion, "get_JointsConstructed") ~= true then
                return "pending", "waiting for target skeleton/IK"
            end
            local ik = get_component(root, "via.motion.IkLeg2")
            if path_of(ik, "get_IkLeg2Asset") ~= "motion/npc/decorate/ikleg/npcikleg_default.ikleg2" then
                return "skipped", "human IK asset changed or unavailable"
            end
            if read(ik, "get_Setuped") ~= true then return "pending", "human IK not ready" end
            local apply, why = get_native()
            if not apply then return "skipped", why end
            local root_transform = get_transform(root)
            local body = current_body(root_transform, plan.body_id)
            if not body then return "pending", "unique direct BODY not ready" end
            local object, transform = body.object, body.transform
            if not is_valid_managed_object(object) or read(transform, "get_SameJointsConstraint") ~= true
                or not same_runtime_object(read(transform, "get_Parent"), root_transform) then
                return "skipped", "BODY ownership/constraint changed"
            end
            local mesh = get_component(object, "via.render.Mesh")
            if not mesh then return "pending", "BODY Mesh not ready" end
            local component_status, component_detail, unchecked_skin, empty_layers = body_components(object)
            if component_status then return component_status, component_detail end
            local root_id, body_id, transform_id, mesh_id = address(root_transform), address(object), address(transform), address(mesh)
            if not root_id or not body_id or not transform_id or not mesh_id then return "skipped", "native identity unavailable" end
            metrics.native_calls = metrics.native_calls + 1
            local result = apply(0x42534638, plan.root, root_id, body_id, transform_id, mesh_id, 0)
             
            if address(root) ~= plan.root or address(object) ~= body_id or address(mesh) ~= mesh_id then
                return "error", "identity changed across native call"
            end
            if result == 2 then return "pending", "native Scene lock busy; throttled retry" end
            if result ~= 0 and result ~= 1 then return "skipped", "native guard=" .. tostring(result) end
            local secondary = get_component(object, "via.motion.ChildSecondary")
            return "applied", "BODY-only four mappings; initial_apply_only; native=" .. result
                .. "; merged=" .. tostring(read(secondary, "get_MergedSkeleton"))
                .. "; control_parent=" .. tostring(read(secondary, "get_ControlParentObject"))
                .. (unchecked_skin and "; SC_allowed_unverified" or "")
                .. (empty_layers and empty_layers > 0 and "; empty_layers=" .. empty_layers or "")
        end)
        if not ok then detail, status = tostring(status), "error" end
        if status == "pending" then
            nonhuman_retry.defer(plan, entry.nonhuman_forefoot, detail, now, max_checks, plan.checks)
            return
        end
        record(entry, status, detail)
    end
    return helper
end)()

 
 
 
 

 
local function inspect_character(character, source, resolution, cache_entry, options)
    if not config.enabled or not character then
        return false, "disabled or nil character"
    end
    options = options or {}
    local root_obj = options.root_obj or get_game_object(character)
    if not root_obj then
        return false, "no root game object"
    end
    local resolution_npc_id = resolution and resolution.npc_id or nil
    local is_player, player_reason = is_any_player_character(character, root_obj, resolution_npc_id == nil)
    if is_player then
        reject_normal_player_character(character, root_obj, cache_entry, player_reason)
        return false, "player_character_rejected"
    end
    local match_status = nil
    if not resolution then
        cache_entry = cache_entry or {}
        resolution, match_status = resolve_target(character, root_obj, cache_entry, options.resolve_options)
    end
    if not resolution or not resolution.target then
        return false, tostring(match_status or "unmatched")
    end
    local target = resolution.target
    local body_id = resolution.body_id
    local match_source = resolution.match_source
    local identity = "npc_id=" .. tostring(resolution.npc_id or "") .. ";chest=" .. tostring(resolution.chest_state and resolution.chest_state.chest_name or "")
    stats.matched = stats.matched + 1
    stats.inspected = stats.inspected + 1
    stats.candidates_ready = 0

    local bone_body_id = target.bone_system_body_id or body_id or target.body_id
    local bone_data, bone_source = load_bone_config(bone_body_id)
    local candidates = build_candidates(root_obj, body_id or target.body_id, options.extra_roots)
    local edit_region_trace = build_edit_region_trace(character, root_obj, candidates, bone_data, target)
    local candidate_reports = {}
    local final_ok = false
    local final_status = "no ready candidate"
    local expected_readiness_signature = options.expected_readiness_signature

    for _, candidate in ipairs(candidates) do
        local normal_bone_state
        local report, motion, custom_skeleton = inspect_candidate(candidate.obj, candidate.label)
        if expected_readiness_signature then
            local current_state, readiness_error = probe_candidate_bone_state(candidate.obj, candidate.label)
            report.joints_constructed = current_state and current_state.joints_constructed == true or false
            report.readiness_status = current_state and "ready" or tostring(readiness_error or "not ready")
            report.readiness_signature_match = current_state and current_state.signature == expected_readiness_signature or false
            if current_state and current_state.signature == expected_readiness_signature then
                motion = current_state.motion
                custom_skeleton = current_state.custom_skeleton
                normal_bone_state = current_state
            else
                motion = nil
                custom_skeleton = nil
                if current_state then
                    final_status = "bone readiness changed before apply"
                end
            end
        end
        table.insert(candidate_reports, report)
        if not final_ok and motion and custom_skeleton and bone_data then
            if config.auto_apply_bone == false then
                final_ok = true
                final_status = "bone disabled by config"
            else
                stats.stage_attempts = stats.stage_attempts + 1
                local nonhuman_plan = cache_entry and registered[tostring(character)] == cache_entry
                    and expected_readiness_signature and nonhuman_ik.prepare(candidate, normal_bone_state, cache_entry, bone_data)
                local fingers_plan = cache_entry and registered[tostring(character)] == cache_entry
                    and expected_readiness_signature and nonhuman_fingers.prepare(candidate, normal_bone_state, cache_entry, bone_data)
                local forefoot_plan = cache_entry and registered[tostring(character)] == cache_entry
                    and expected_readiness_signature and nonhuman_forefoot.prepare(candidate, normal_bone_state, cache_entry, bone_data, body_id or target.body_id)
                final_ok, final_status = perform_stage(candidate, motion, custom_skeleton, target, bone_body_id, bone_data)
                if nonhuman_plan then nonhuman_ik.finish(nonhuman_plan, final_ok, cache_entry) end
                if fingers_plan then nonhuman_fingers.finish(fingers_plan, final_ok, cache_entry) end
                if forefoot_plan then nonhuman_forefoot.finish(forefoot_plan, final_ok, cache_entry) end
                if final_ok then
                    stats.stage_ok = stats.stage_ok + 1
                end
            end
        end
    end

    if not bone_data then
        final_status = tostring(bone_source)
    end

    local armor_variant_ok = false
    local armor_variant_status = "not attempted"
    if final_ok then
        armor_variant_ok, armor_variant_status = apply_armor_variant_with_api(character, target, bone_body_id or body_id or target.body_id, options)
    end

    local inspection = {
        time = os.clock(),
        source = source,
        target = target.display_name or target.npc_id,
        body_id = body_id or target.body_id,
        bone_body_id = bone_body_id,
        bone_source = tostring(bone_source),
        root = tostring(root_obj),
        root_name = get_game_object_name(root_obj),
        identity = trim_text(identity, 1200),
        candidate_count = #candidates,
        candidates = candidate_reports,
        edit_region_trace = edit_region_trace,
        status = tostring(final_status),
        armor_variant_status = tostring(armor_variant_status),
        armor_variant_ok = armor_variant_ok,
        private_face_mode = use_private_face_mode(target),
        ok = final_ok
    }
    table.insert(diagnostics.inspections, inspection)
    while #diagnostics.inspections > 8 do
        table.remove(diagnostics.inspections, 1)
    end

    local label = tostring(target.display_name or target.npc_id or "target")
    stats.last_status = label .. " via " .. tostring(match_source or source) .. ": " .. tostring(final_status)
    if not final_ok then
        stats.last_error = tostring(final_status)
    end
    record_event(final_ok and "stage_ok" or "stage_failed", stats.last_status)
    if options.defer_report ~= true then
        write_report(true)
    end
    bs_log(stats.last_status)
    return final_ok, stats.last_status, target, body_id or target.body_id, bone_body_id, armor_variant_status, armor_variant_ok
end

 
 
 
 

local function probe_field_quiet(obj, field_name)
    if not obj or type(field_name) ~= "string" then
        return false, nil
    end
    local ok, result = pcall(function()
        return obj:get_field(field_name)
    end)
    return ok, result
end

local EVENT_GAME_OBJECT_METHODS = {
    "get_GameObject",
    "get_GameObjectRefValue",
    "get_BodyGameObject",
    "get_FaceGameObject",
    "get_TargetGameObject",
    "get_OwnerGameObject",
    "get_ValidGameObject",
    "get_Value"
}

local function accept_event_game_object(value)
    if not value then
        return nil, nil
    end
    if get_game_object_name_quiet(value) ~= "" then
        return value, "self"
    end
    local nested = get_game_object_quiet(value)
    if nested and get_game_object_name_quiet(nested) ~= "" then
        return nested, "get_GameObject"
    end
    return nil, nil
end

local function resolve_event_game_object(value)
    if not value then
        return nil, "nil"
    end
    local direct, direct_route = accept_event_game_object(value)
    if direct then
        return direct, direct_route
    end
    for _, method_name in ipairs(EVENT_GAME_OBJECT_METHODS) do
        local ok, candidate = probe_call(value, method_name)
        if ok and candidate and candidate ~= value then
            local game_obj = accept_event_game_object(candidate)
            if game_obj then
                return game_obj, method_name
            end
        end
    end
    for _, field_name in ipairs({ "_GameObject", "GameObject", "_Value", "Value" }) do
        local ok, candidate = probe_field_quiet(value, field_name)
        if ok and candidate and candidate ~= value then
            local game_obj = accept_event_game_object(candidate)
            if game_obj then
                return game_obj, field_name
            end
        end
    end
    return nil, "unresolved"
end

 
local function build_event_model_context(setupper)
    local context = {
        owner = get_game_object_quiet(setupper),
        npc_id = nil,
        npc_raw = "",
        model_parts_data = nil,
        pl_equip = nil,
        pl_equip_objects = {},
        body_object = nil,
        body_name = "",
        body_id = nil,
        body_source = "none",
        extra_roots = {},
        reference_routes = {}
    }
    local object_seen = {}
    local function add_object(label, obj, route)
        if not obj then
            return
        end
        local key = tostring(obj)
        context.reference_routes[label] = tostring(route or "")
        if not object_seen[key] and obj ~= context.owner then
            object_seen[key] = true
            table.insert(context.extra_roots, obj)
        end
    end

    local ok_npc, npc_value = probe_field_quiet(setupper, "_NpcID")
    if ok_npc and npc_value ~= nil then
        context.npc_raw = tostring(npc_value)
        context.npc_id = npc_id_from_serializable(npc_value)
    end
    context.npc_id = context.npc_id or read_npc_id(setupper, context.owner)

    local ok_equip, pl_equip = probe_field_quiet(setupper, "_PlEquip")
    if ok_equip and pl_equip then
        context.pl_equip = pl_equip
        for part_index = 0, 5 do
            local ok_part, part = pcall(function()
                return pl_equip[part_index]
            end)
            if ok_part and part then
                local game_obj, route = resolve_event_game_object(part)
                context.pl_equip_objects[tostring(part_index)] = {
                    raw = trim_text(part, 180),
                    object = tostring(game_obj),
                    name = get_game_object_name_quiet(game_obj),
                    route = tostring(route or "")
                }
                add_object("pl_equip_" .. tostring(part_index), game_obj,
                    "_PlEquip[" .. tostring(part_index) .. "]:" .. tostring(route or ""))
                if part_index == 1 and game_obj then
                    context.body_object = game_obj
                    context.body_source = "event_model_pl_equip"
                end
            end
        end
    end

    if not context.body_object then
        local ok_parts, model_parts_data = probe_field_quiet(setupper, "_ModelPartsData")
        if ok_parts then
            context.model_parts_data = model_parts_data
        end
        if model_parts_data then
            local ok_ref, reference = probe_field_quiet(model_parts_data, "_BodyTarget")
            if ok_ref and reference then
                local game_obj, route = resolve_event_game_object(reference)
                add_object("body", game_obj, "_BodyTarget:" .. tostring(route or ""))
                if game_obj then
                    context.body_object = game_obj
                    context.body_source = "event_model_body_target"
                end
            end
        end
    end

    if context.body_object then
        context.body_name = get_game_object_name_quiet(context.body_object)
        context.body_id = body_id_from_object_name(context.body_name)
    end
    context.chest_state = {
        chest_object = context.body_object,
        chest_name = context.body_name,
        chest_body_id = context.body_id,
        source = context.body_source,
        cache_route = "event_model"
    }
    return context
end

local function new_event_cache_entry()
    return {
        dictionary_generation = 0,
        npc_id = nil,
        chest_object = nil,
        chest_name = "",
        chest_body_id = nil,
        outfit_source = "none",
        fallback_object = nil,
        fallback_name = "",
        fallback_body_id = nil,
        fallback_source = nil,
        resolved_target = nil,
        session_unmatched_key = nil,
        session_unmatched_generation = nil,
        unmatched_attempts = 0,
        applied = false
    }
end

local function remember_event_model_setup(item)
    table.insert(diagnostics.event_model_setups, item)
    while #diagnostics.event_model_setups > 16 do
        table.remove(diagnostics.event_model_setups, 1)
    end
end

 
local function process_event_model_setupper(setupper)
    local context = build_event_model_context(setupper)
    local diagnostic = {
        time = os.clock(),
        setupper = tostring(setupper),
        owner = tostring(context.owner),
        owner_name = get_game_object_name_quiet(context.owner),
        npc_id = tostring(context.npc_id or ""),
        npc_raw = trim_text(context.npc_raw, 180),
        model_parts_data = tostring(context.model_parts_data),
        pl_equip = tostring(context.pl_equip),
        pl_equip_objects = context.pl_equip_objects,
        body_object = tostring(context.body_object),
        body_name = tostring(context.body_name or ""),
        body_id = tostring(context.body_id or ""),
        body_source = tostring(context.body_source or ""),
        reference_routes = context.reference_routes,
        status = "started",
        ok = false
    }
    if not context.owner then
        diagnostic.status = "no EventModelSetupper owner"
        performance.event_model_errors = performance.event_model_errors + 1
        remember_event_model_setup(diagnostic)
        write_report(false)
        return false, diagnostic.status
    end

    local cache_entry = new_event_cache_entry()
    local resolution, match_status = resolve_target(setupper, context.owner, cache_entry, {
        npc_id = context.npc_id,
        chest_state = context.chest_state,
        extra_roots = context.extra_roots,
        disable_session_cache = true
    })
    diagnostic.match_status = tostring(match_status or (resolution and resolution.match_source) or "unmatched")
    if not resolution then
        diagnostic.status = diagnostic.match_status
        performance.event_model_unmatched = performance.event_model_unmatched + 1
        remember_event_model_setup(diagnostic)
        record_event("event_model_unmatched", diagnostic.status .. " npc_id=" .. diagnostic.npc_id)
        write_report(false)
        return false, diagnostic.status
    end

    diagnostic.target = tostring(resolution.target and (resolution.target.display_name or resolution.target.npc_id) or "")
    diagnostic.resolved_body_id = tostring(resolution.body_id or "")
    performance.event_model_apply_attempts = performance.event_model_apply_attempts + 1
    local ok, detail, _, _, _, armor_variant_status, armor_variant_ok = inspect_character(
        setupper,
        "app.EventModelSetupper.setupModelPartsNpc",
        resolution,
        cache_entry,
        {
            root_obj = context.owner,
            extra_roots = context.extra_roots,
            defer_report = true
        }
    )
    diagnostic.ok = ok == true
    diagnostic.status = tostring(detail or "")
    diagnostic.armor_variant_status = tostring(armor_variant_status or "")
    diagnostic.armor_variant_ok = armor_variant_ok == true
    if ok then
        performance.event_model_apply_ok = performance.event_model_apply_ok + 1
    else
        performance.event_model_errors = performance.event_model_errors + 1
    end
    if armor_variant_ok then
        performance.event_model_variant_ok = performance.event_model_variant_ok + 1
    end
    remember_event_model_setup(diagnostic)
    record_event(ok and "event_model_stage_ok" or "event_model_stage_failed", diagnostic.status)
    write_report(false)
    return ok, diagnostic.status
end

local function event_setup_completed(retval)
    if not sdk or type(sdk.to_int64) ~= "function" then
        return false, "sdk.to_int64 unavailable"
    end
    local ok, complete, raw = pcall(function()
        local value = sdk.to_int64(retval)
        return (value & 1) ~= 0, tostring(value)
    end)
    if not ok then
        return false, tostring(complete)
    end
    return complete == true, tostring(raw or "")
end

 
local function install_event_model_npc_hook()
    if not thread or type(thread.get_hook_storage) ~= "function" then
        hook_state.event_model_npc = "thread.get_hook_storage unavailable"
        return false
    end
    local type_name = "app.EventModelSetupper"
    local td = safe_sdk_type(type_name)
    if not td then
        hook_state.event_model_npc = type_name .. " not found"
        return false
    end
    local method = nil
    local ok_method = pcall(function()
        method = td:get_method("setupModelPartsNpc") or td:get_method("setupModelPartsNpc()")
    end)
    if not ok_method or not method then
        hook_state.event_model_npc = "no hookable method app.EventModelSetupper.setupModelPartsNpc"
        return false
    end
    local storage_key = "bsfn_setup_model_parts_npc_this"
    local suppressed_storage_key = "bsfn_setup_model_parts_npc_suppressed"
    local ok_hook, err = pcall(function()
        sdk.hook(method, function(args)
            local ok_storage, storage = pcall(thread.get_hook_storage)
            if not ok_storage or not storage then
                return
            end
            storage[storage_key] = nil
            storage[suppressed_storage_key] = nil
            if scene_transition.active then
                storage[suppressed_storage_key] = true
                performance.scene_event_model_suppressed = performance.scene_event_model_suppressed + 1
                return
            end
            local ok_obj, setupper = pcall(function()
                return sdk.to_managed_object(args[2])
            end)
            if ok_obj and setupper then
                storage[storage_key] = setupper
            end
        end, function(retval)
            performance.event_model_hook_hits = performance.event_model_hook_hits + 1
            local ok_storage, storage = pcall(thread.get_hook_storage)
            local setupper = ok_storage and storage and storage[storage_key] or nil
            local suppressed = ok_storage and storage and storage[suppressed_storage_key] == true
            if storage then
                storage[storage_key] = nil
                storage[suppressed_storage_key] = nil
            end
            if suppressed or scene_transition.active then
                return retval
            end
            local completed, raw_result = event_setup_completed(retval)
            if not completed then
                performance.event_model_incomplete_skips = performance.event_model_incomplete_skips + 1
                return retval
            end
            if config.enabled == false then
                return retval
            end
            performance.event_model_completed_hits = performance.event_model_completed_hits + 1
            if not setupper then
                performance.event_model_errors = performance.event_model_errors + 1
                record_event("event_model_error", "completed setup without saved this; ret=" .. tostring(raw_result))
                write_report(false)
                return retval
            end
            local ok_process, process_error = pcall(process_event_model_setupper, setupper)
            if not ok_process then
                performance.event_model_errors = performance.event_model_errors + 1
                stats.last_error = tostring(process_error)
                record_event("event_model_error", tostring(process_error))
                write_report(false)
            end
            return retval
        end)
    end)
    if not ok_hook then
        hook_state.event_model_npc = tostring(err)
        return false
    end
    hook_state.event_model_npc = "installed app.EventModelSetupper.setupModelPartsNpc"
    record_event("hook", hook_state.event_model_npc)
    write_report(false)
    return true
end

 
 
 
 

 
local function register_character(character, source)
    if not character or scene_transition.active then
        return
    end
    local key = tostring(character)
    if normal_player_rejections[key] then
        return
    end
    local entry = registered[key]
    local now = normal_runtime_clock()
    if not entry or entry.scene_generation ~= scene_generation then
        stats.seen = stats.seen + 1
        registered[key] = {
            character = character,
            source = source or "unknown",
            first_seen = now,
            last_seen = now,
            last_inspect = -9999,
            scene_generation = scene_generation,
            dictionary_generation = 0,
            npc_id = nil,
            chest_object = nil,
            chest_name = "",
            chest_body_id = nil,
            outfit_source = "none",
            fallback_object = nil,
            fallback_name = "",
            fallback_body_id = nil,
            fallback_source = nil,
            resolved_target = nil,
            session_unmatched_key = nil,
            session_unmatched_generation = nil,
            unmatched_attempts = 0,
            pending_target = nil,
            pending_body_id = nil,
            pending_bone_body_id = nil,
            pending_match_source = nil,
            pending_dictionary_generation = nil,
            pending_key = nil,
            readiness_signature = nil,
            readiness_stable_frames = 0,
            readiness_burst_checks = 0,
            readiness_holder_address = nil,
            next_readiness_probe = nil,
            readiness_status = "not started",
            player_character_rejected = false,
            applied = false
        }
    else
        entry.character = character
        entry.source = source or entry.source
        entry.last_seen = now
    end
end

local function install_hook(type_name, method_names, state_key)
    local td = safe_sdk_type(type_name)
    if not td then
        hook_state[state_key] = type_name .. " not found"
        return
    end
    for _, method_name in ipairs(method_names) do
        local ok_method, method = pcall(function()
            return td:get_method(method_name)
        end)
        if ok_method and method then
            local ok_hook, err = pcall(function()
                sdk.hook(method, function(args)
                    if scene_transition.active then
                        performance.scene_registration_suppressed = performance.scene_registration_suppressed + 1
                        return
                    end
                    local ok_obj, character = pcall(function()
                        return sdk.to_managed_object(args[2])
                    end)
                    if ok_obj and character and not normal_runtime_menu_suspended then
                        register_character(character, type_name .. "." .. method_name)
                    end
                end)
            end)
            if ok_hook then
                hook_state[state_key] = "installed " .. type_name .. "." .. method_name
                record_event("hook", hook_state[state_key])
                write_report(true)
                return
            end
            hook_state[state_key] = tostring(err)
        end
    end
    if hook_state[state_key] == "not attempted" then
        hook_state[state_key] = "no hookable method on " .. type_name
    end
end

local function apply_registered_armor_variants(now)
    if config.auto_sync_armor_variant == false then
        return
    end
    local interval = tonumber(config.armor_variant_reapply_interval) or 0.7
    if interval <= 0 or now - last_armor_variant_sync_time < interval then
        return
    end
    last_armor_variant_sync_time = now
    local recent_window = tonumber(config.armor_variant_recent_seen_window) or 1.0
    for key, entry in pairs(registered) do
        if not entry.character or not is_valid_managed_object(entry.character) or now - entry.last_seen > recent_window then
            entry.armor_variant_status = "skipped stale registered entry"
            record_event("stale registered entry", tostring(key))
        elseif entry.applied and entry.character and entry.target then
            local ok, status = apply_armor_variant_with_api(entry.character, entry.target, entry.bone_body_id or entry.body_id)
            entry.armor_variant_ok = ok
            entry.armor_variant_status = status
        end
    end
end

 
local function apply_ready_registered_entry(entry, ready_state)
    local pending_target = entry.pending_target
    local pending_body_id = entry.pending_body_id
    local pending_bone_body_id = entry.pending_bone_body_id
    local expected_signature = ready_state and ready_state.signature or entry.readiness_signature
    if not expected_signature then
        clear_entry_readiness(entry, "missing final readiness signature", false)
        entry.next_readiness_probe = normal_runtime_clock() + (tonumber(config.readiness_retry_interval) or 0.1)
        return false
    end

     
     
     
    local root_ok, root_obj = safe_call(entry.character, "get_GameObject")
    if not root_ok or not root_obj then
        performance.game_object_failures = performance.game_object_failures + 1
        clear_entry_readiness(entry, "final root GameObject unavailable", false)
        entry.next_readiness_probe = normal_runtime_clock() + (tonumber(config.readiness_retry_interval) or 0.1)
        return false
    end
    clear_fallback_cache(entry)
    if entry.session_unmatched_key then
        session_unmatched_cache[entry.session_unmatched_key] = nil
    end
    entry.session_unmatched_key = nil
    entry.session_unmatched_generation = nil
    local resolution, match_status = resolve_target(entry.character, root_obj, entry)
    entry.match_status = match_status or (resolution and resolution.match_source) or "unmatched"
    if not resolution then
        clear_entry_readiness(entry, "final target resolution failed: " .. tostring(entry.match_status), true)
        return false
    end
    local target = resolution.target
    local current_body_id = resolution.body_id or (target and target.body_id)
    local current_bone_body_id = target and (target.bone_system_body_id or current_body_id or target.body_id) or nil
    if target ~= pending_target
        or tostring(current_body_id or "") ~= tostring(pending_body_id or "")
        or tostring(current_bone_body_id or "") ~= tostring(pending_bone_body_id or "") then
        performance.readiness_final_mismatches = performance.readiness_final_mismatches + 1
        clear_entry_readiness(entry, "target changed before final apply", true)
        return false
    end

    local ok, detail, matched_target, matched_body_id, matched_bone_body_id, armor_variant_status =
        inspect_character(entry.character, entry.source, resolution, entry, {
            root_obj = root_obj,
            expected_readiness_signature = expected_signature
        })
    if not ok then
        performance.readiness_final_mismatches = performance.readiness_final_mismatches + 1
        begin_entry_readiness(entry, resolution)
        clear_entry_readiness(entry, "final apply deferred: " .. tostring(detail), false)
        entry.next_readiness_probe = normal_runtime_clock() + (tonumber(config.readiness_retry_interval) or 0.1)
        return false
    end
    entry.applied = true
    entry.target = matched_target
    entry.resolved_target = matched_target
    entry.body_id = matched_body_id
    entry.bone_body_id = matched_bone_body_id
    entry.armor_variant_status = armor_variant_status
    clear_entry_readiness(entry, "applied", true)
    return true
end

 
local function update_registered()
    local now = normal_runtime_clock()
    local inspect_interval = tonumber(config.inspect_interval) or 1.0
    local entry_ttl = tonumber(config.registered_entry_ttl) or 3.0
    for key, entry in pairs(registered) do
        if entry.scene_generation ~= scene_generation then
            record_event("stale_scene_generation", tostring(key))
            registered[key] = nil
        elseif entry.player_character_rejected then
            registered[key] = nil
        elseif not entry.character or not is_valid_managed_object(entry.character) or now - entry.last_seen > entry_ttl then
            record_event("stale_registered_entry", tostring(key))
            registered[key] = nil
        elseif config.enabled then
            if entry.nonhuman_ik_pending then nonhuman_ik.update(entry, now) end
            if entry.nonhuman_fingers_pending then nonhuman_fingers.update(entry, now) end
            if entry.nonhuman_forefoot_pending then nonhuman_forefoot.update(entry, now) end
            if entry.pending_target and config.auto_apply_bone ~= false then
                local ready_state = update_entry_readiness(entry, now)
                if ready_state then
                    apply_ready_registered_entry(entry, ready_state)
                end
            elseif now - entry.last_inspect >= inspect_interval then
                entry.last_inspect = now
                local same_generation = entry.dictionary_generation == dictionary_generation
                local session_cached = entry.session_unmatched_key
                    and entry.session_unmatched_generation == dictionary_generation
                    and session_unmatched_cache[entry.session_unmatched_key]
                if session_cached then
                    performance.session_unmatched_cache_hits = performance.session_unmatched_cache_hits + 1
                    entry.match_status = "unmatched_session_cache"
                elseif config.apply_once == true and entry.applied and entry.target and same_generation then
                    performance.apply_once_fast_skips = performance.apply_once_fast_skips + 1
                    entry.match_status = "apply_once_cached"
                else
                    local root_ok, root_obj = safe_call(entry.character, "get_GameObject")
                    if not root_ok or not root_obj then
                        performance.game_object_failures = performance.game_object_failures + 1
                        record_event("registered_game_object_failed", tostring(key))
                        registered[key] = nil
                    else
                        local resolution, match_status = resolve_target(entry.character, root_obj, entry)
                        entry.match_status = match_status or (resolution and resolution.match_source) or "unmatched"
                        if resolution and (config.apply_once ~= true or not entry.applied or resolution.cache_changed) then
                            if config.auto_apply_bone == false then
                                local ok, _, matched_target, matched_body_id, matched_bone_body_id, armor_variant_status =
                                    inspect_character(entry.character, entry.source, resolution, entry)
                                if ok then
                                    entry.applied = true
                                    entry.target = matched_target
                                    entry.resolved_target = matched_target
                                    entry.body_id = matched_body_id
                                    entry.bone_body_id = matched_bone_body_id
                                    entry.armor_variant_status = armor_variant_status
                                end
                            else
                                if begin_entry_readiness(entry, resolution) then
                                    local ready_state = update_entry_readiness(entry, now)
                                    if ready_state then
                                        apply_ready_registered_entry(entry, ready_state)
                                    end
                                end
                            end
                        end
                    end
                end
            end
        end
    end
    apply_registered_armor_variants(now)
    write_report(false)
end

 
 
 
 

local function make_persisted_config()
    local persisted = copy_table(config or {})
    persisted.targets = nil
    persisted.manual_targets_enabled = nil
    persisted.auto_discover_bonesystem_outfits = nil
    return persisted
end

local function save_config()
    if not json or type(json.dump_file) ~= "function" then
        return
    end
    local ok, err = pcall(function()
        json.dump_file(CONFIG_PATH, make_persisted_config())
    end)
    if not ok then
        stats.last_error = "save_config: " .. tostring(err)
        record_event("save_config_failed", stats.last_error)
    end
end

local function checkbox(label, value)
    if not imgui or type(imgui.checkbox) ~= "function" then
        return false, value
    end
    local ok, a, b = pcall(imgui.checkbox, label, value)
    if ok and type(a) == "boolean" and type(b) == "boolean" then
        return a, b
    end
    if ok and type(a) == "boolean" then
        return a ~= value, a
    end
    return false, value
end

local function draw_bool(label, key)
    local changed, value = checkbox(label, config[key] == true)
    if changed then
        config[key] = value
        save_config()
        write_report(true)
    end
end

local function draw_ui()
    if not config.ui_enabled or not imgui or type(imgui.tree_node) ~= "function" then
        return
    end
    if not imgui.tree_node(MOD_NAME .. " v" .. VERSION) then
        return
    end

    draw_bool(T("enabled"), "enabled")

    if imgui.tree_node(T("language")) then
        local changed_zh, new_zh = checkbox(T("language_zh"), config.language == "zh")
        if changed_zh and new_zh then
            config.language = "zh"
            save_config()
        end
        local changed_en, new_en = checkbox(T("language_en"), config.language == "en")
        if changed_en and new_en then
            config.language = "en"
            save_config()
        end
        imgui.tree_pop()
    end

    if imgui.tree_node(T("advanced")) then
        draw_bool(T("auto_apply_face_mapping"), "auto_apply_face_mapping")
        draw_bool(T("auto_sync_armor_variant"), "auto_sync_armor_variant")
        imgui.tree_pop()
    end

    if imgui.tree_node(T("debug")) then
        draw_bool(T("write_report"), "write_report")
        draw_bool(T("debug_log"), "debug_log")
        if imgui.button(T("reload_config")) then
            load_config()
            write_report(true)
        end
        if imgui.button(T("write_report_now")) then
            local old_write_report = config.write_report
            config.write_report = true
            write_report(true)
            config.write_report = old_write_report
        end
        imgui.text(T("status") .. ": " .. tostring(stats.last_status))
        imgui.text(T("targets") .. ": manual=" .. tostring(stats.manual_targets) .. ", auto=" .. tostring(stats.auto_targets))
        imgui.text(T("scan") .. ": " .. tostring(stats.bone_system_configs))
        imgui.text(T("avm") .. ": " .. tostring(diagnostics.armor_variant and diagnostics.armor_variant.status or ""))
        imgui.tree_pop()
    end

    imgui.tree_pop()
end

 
 
 
 

load_config()
record_event("loaded", "outfit target loader active; mode=" .. tostring(config.mode) .. "; targets=" .. tostring(#get_targets()))
install_scene_transition_hook()
install_hook("app.NpcCharacter", { "update", "doStartBegin", "doStartEnd" }, "npc")
install_event_model_npc_hook()

if re and re.on_application_entry then
    if scene_transition_hook_installed then
        re.on_application_entry("UpdateMotion", function()
            scene_transition.initialize_context()
            if scene_transition.update() then
                return
            end
            if not update_normal_runtime_menu_pause() then
                update_registered()
            end
        end)
        hook_state.update = "installed UpdateMotion with deferred scene quarantine release, constructed-skeleton readiness, and GUI050000 quest-list pause"
    else
        re.on_application_entry("UpdateMotion", function()
            update_scene_generation_fallback()
            if scene_transition.update() then
                return
            end
            if not update_normal_runtime_menu_pause() then
                update_registered()
            end
        end)
        hook_state.update = "installed UpdateMotion with one-second SceneManager fallback, constructed-skeleton readiness, and GUI050000 quest-list pause"
    end
else
    hook_state.update = "re.on_application_entry unavailable"
    record_event("error", hook_state.update)
end

if re and re.on_draw_ui then
    re.on_draw_ui(function()
        local ok, err = pcall(draw_ui)
        if not ok then
            stats.last_error = tostring(err)
        end
    end)
end

_G.BoneSystemForNPC = {
    version = VERSION,
    stats = stats,
    performance = performance,
    diagnostics = diagnostics,
    hook_state = hook_state,
    inspect_character = inspect_character,
    resolve_target = resolve_target,
    process_event_model_setupper = process_event_model_setupper,
    load_config = load_config,
    scan_bone_system_configs = scan_bone_system_configs,
    get_scene_generation = function() return scene_generation end,
    is_scene_transition_active = function() return scene_transition.active end
}
write_report(true)
bs_log("loaded")

 
 
local function quest_object_address(object)
    if not object then return end
    local ok, address = pcall(function() return object:get_address() end)
    if not ok or type(address) ~= "number" then return end
    address = math.tointeger(address)
    if address and address > 0 then return address end
end

 
 
local function make_quest_face_relay(field, call, edit_root_for, quest)
    local ticket
    local relay = {}
    local properties = { "LocalPosition", "LocalRotation", "LocalScale" }
    local axes = { "x", "y", "z", "w" }

    local function finite(value)
        return type(value) == "number" and value == value and math.abs(value) < math.huge
    end

     
    local function facial_name(name)
        if type(name) ~= "string" or #name > 96 then return false end
        if name == "L_Eye" or name == "R_Eye" then return true end
        if name == "L_Eye_Master" or name == "R_Eye_Master" or name == "C_Mouth_Master" then return true end
        local stem = name:match("^[LRC]_(.-)_LOD%d%d$")
        if not stem then return false end
        stem = stem:lower()
        for _, token in ipairs({ "eye", "brow", "lip", "jaw", "cheek", "nose",
            "nostril", "chin", "mouth", "tongue", "teeth", "forehead" }) do
            if stem:find(token, 1, true) then return true end
        end
        return false
    end

    local function stop(state, reason)
        if ticket == state then ticket = nil end
        state.relay_enabled = nil
        state.relay_map = nil
        if state.face_relay then state.face_relay.status = reason end
    end

     
    local function build_map(source, target)
        local joints = call(source, "get_Joints")
        local count = tonumber(joints and call(joints, "get_Length"))
        assert(count and count > 0 and count <= 768 and count % 1 == 0, "invalid source joint count")
        local result, seen = {}, {}
        for index = 0, count - 1 do
            local joint = call(joints, "get_Item", index)
            local name = joint and call(joint, "get_Name")
            if facial_name(name) and not seen[name] then
                seen[name] = true
                local other = call(target, "getJointByName", name)
                if other and call(joint, "get_Valid") == true and call(other, "get_Valid") == true then
                    local item = { name = name, deltas = {} }
                    for _, property in ipairs(properties) do
                        local a = assert(call(joint, "get_Base" .. property), "missing source base")
                        local b = assert(call(other, "get_Base" .. property), "missing target base")
                        local delta = {}
                        for axis = 1, property == "LocalRotation" and 4 or 3 do
                            local key = axes[axis]
                            assert(finite(a[key]) and finite(b[key]), "nonfinite base pose")
                            delta[key] = b[key] - a[key]
                        end
                        item.deltas[property] = delta
                    end
                    result[#result + 1] = item
                    assert(#result <= 192, "facial map budget exceeded")
                end
            end
        end
        assert(#result > 0, "no matching facial joints")
        return result
    end

    local function current_action()
        local manager = sdk.get_managed_singleton("app.PlayerManager")
        local player = manager and call(manager, "getMasterPlayer")
        local character = player and call(player, "get_Character")
        local controller = character and call(character, "get_BaseActionController")
        return controller and call(controller, "get_CurrentAction")
    end

    local function transfer(state)
        local action = current_action()
        if not action or quest_object_address(action) ~= state.key then return stop(state, "current action changed") end
        local phase = tonumber(field(action, "_Phase"))
        if phase ~= 1 and phase ~= 2 and phase ~= 3 then return stop(state, "result phase ended") end
        local motion = field(action, "_NpcMotionComponent")
        local owner = motion and get_game_object_quiet(motion)
        local creator = field(action, "_NpcVisualCreator")
        local player = field(action, "_Chara")
        if not owner or quest_object_address(owner) ~= state.owner_address
            or quest_object_address(motion) ~= state.motion_address
            or not same_runtime_object(owner, get_game_object_quiet(creator))
            or get_component(owner, "app.HunterCharacter")
            or (player and same_runtime_object(owner, get_game_object_quiet(player))) then
            return stop(state, "NPC owner changed")
        end
        local root = edit_root_for(owner)
        local face = root and call(root, "getPartsObject", 935285574)
        local part = root and call(root, "getPartsObject", state.relay_bind_hash)
        if not face or not part or same_runtime_object(face, part) or same_runtime_object(owner, part)
            or quest_object_address(face) ~= state.relay_face or quest_object_address(part) ~= state.relay_part then
            return stop(state, "face or outfit part changed")
        end
        local part_motion = get_component(part, "via.motion.Motion")
        local driver = part_motion or get_component(part, "via.motion.ChildSecondary")
        if not driver or quest_object_address(driver) ~= state.face_bind_driver_address then
            return stop(state, "binding driver changed")
        end
        local part_construction = part_motion and tonumber(call(part_motion, "get_SkeletonConstructCount")) or -1
        if part_motion and (part_construction == -1 or call(part_motion, "get_JointsConstructed") ~= true) then
            return stop(state, "outfit joints not ready")
        end
        local face_motion = get_component(face, "via.motion.Motion")
        local source_motion_address = quest_object_address(face_motion)
        if not source_motion_address then return stop(state, "source motion identity unavailable") end
        local constructed = call(motion, "get_JointsConstructed")
        local source_ready = face_motion and call(face_motion, "get_JointsConstructed")
        if constructed ~= true or source_ready ~= true then return stop(state, "joints no longer constructed") end
        local construction = tonumber(call(motion, "get_SkeletonConstructCount"))
        local source_construction = tonumber(call(face_motion, "get_SkeletonConstructCount"))
        if not construction or not source_construction then return stop(state, "missing construction identity") end
        local source, target = get_transform(face), get_transform(part)
        if not source or not target then return stop(state, "missing current transform") end
        if not state.relay_map then
            state.relay_map = build_map(source, target)
            state.relay_construction, state.relay_source_construction = construction, source_construction
            state.relay_part_construction = part_construction
            state.relay_source_motion = source_motion_address
            state.face_relay.joint_count = #state.relay_map
            state.face_relay.joints = {}
            for _, item in ipairs(state.relay_map) do state.face_relay.joints[#state.face_relay.joints + 1] = item.name end
        elseif state.relay_construction ~= construction or state.relay_source_construction ~= source_construction
            or state.relay_source_motion ~= source_motion_address or state.relay_part_construction ~= part_construction then
            return stop(state, "skeleton reconstructed; old map discarded")
        end

         
         
        local writes = 0
        for _, item in ipairs(state.relay_map) do
            local a = call(source, "getJointByName", item.name)
            local b = call(target, "getJointByName", item.name)
            assert(a and b and call(a, "get_Valid") == true and call(b, "get_Valid") == true,
                "mapped joint became invalid")
            for _, property in ipairs(properties) do
                local value = assert(call(a, "get_" .. property), "missing animated pose")
                for axis = 1, property == "LocalRotation" and 4 or 3 do
                    local key = axes[axis]
                    assert(finite(value[key]), "nonfinite animated pose")
                    value[key] = value[key] + item.deltas[property][key]
                    assert(finite(value[key]), "nonfinite transferred pose")
                end
                local ok, err = call_any(b, "set_" .. property, value)
                assert(ok, tostring(err))
                writes = writes + 1
            end
        end
        local info = state.face_relay
        info.frames, info.writes, info.status = info.frames + 1, info.writes + writes, "copying facial joints"
         
        if state.diagnostics and (info.frames == 1 or info.frames == 30 or info.frames == 120) then
            local sample = { frame = info.frames, time = os.clock(), joints = {} }
            for _, name in ipairs({ "L_UpEyeLidJ_LOD02", "C_upLip_LOD02", "C_Jaw_LOD02" }) do
                local joint = call(target, "getJointByName", name)
                local rotation = joint and call(joint, "get_LocalRotation")
                if rotation then
                    sample.joints[name] = { x = rotation.x, y = rotation.y, z = rotation.z, w = rotation.w }
                end
            end
            info.samples[#info.samples + 1] = sample
        end
    end

    function relay.arm(state, face, part, bind_hash)
        state.relay_bind_hash = bind_hash
        state.relay_face, state.relay_part = quest_object_address(face), quest_object_address(part)
        state.face_relay = { action = state.key, owner = state.owner, body_id = state.body_id,
            owner_address = state.owner_address, motion_address = state.motion_address,
            face_address = state.relay_face, part_address = state.relay_part,
            driver_address = state.face_bind_driver_address,
            status = "waiting for late animation phase", frames = 0, writes = 0, samples = {},
            started = os.clock(), timing_enabled = state.diagnostics == true,
            total_ms = state.diagnostics and 0 or nil, peak_ms = state.diagnostics and 0 or nil }
        quest.face_relays[#quest.face_relays + 1] = state.face_relay
        if #quest.face_relays > 4 then table.remove(quest.face_relays, 1) end
        if not state.relay_face or not state.relay_part or not state.face_bind_driver_address then
            return stop(state, "face or binding identity unavailable")
        end
        state.relay_enabled = true
    end

    function relay.queue(state)
        if state.relay_enabled then ticket = state end
    end

    relay.stop = stop
    if re and re.on_pre_application_entry then
        re.on_pre_application_entry("LockScene", function()
             
            local state = ticket
            if not state then return end
            ticket = nil
            if not state.relay_enabled or not config.enabled or config.auto_apply_face_mapping == false or scene_transition.active
                or state.generation ~= scene_generation then
                stop(state, "result relay suspended")
                return
            end
            if os.clock() - state.face_relay.started > 60 or state.face_relay.frames >= 20000 then
                stop(state, "result relay budget ended")
                return
            end
            local started = os.clock()
            local ok, err = pcall(transfer, state)
            local info = state.face_relay
            if state.diagnostics then
                local elapsed = (os.clock() - started) * 1000
                info.total_ms, info.peak_ms = info.total_ms + elapsed, math.max(info.peak_ms, elapsed)
            end
            if not ok then
                info.error = tostring(err)
                quest.relay_errors = quest.relay_errors + 1
                stop(state, "relay failed; no retry for this action")
            end
        end)
        relay.available = true
    end
    return relay
end

 
 
 
 
 
 
 
local function make_quest_visibility_guard(field, call, edit_root_for)
    local guard = {}
    local interval, max_checks, max_nodes, max_materials = 0.1, 600, 32, 128
     
    local get_option
    if debug and type(debug.getupvalue) == "function" then
        for index = 1, 16 do
            local ok, name, value = pcall(debug.getupvalue, API.fix_bone, index)
            if not ok or not name then break end
            if name == "get_config_data" and type(value) == "function" then get_option = value; break end
        end
    end

    function guard.stop(state, reason)
        if state.visibility_pending and state.visibility then state.visibility.status = reason end
        state.visibility_pending = nil
        state.visibility_protected = nil
        state.visibility_options = nil
    end

    function guard.arm(state, face, data, root, owner)
        if not get_option then
            state.visibility = { status = "original visibility options unavailable; no extra writes", checks = 0, writes = 0 }
            return
        end
        local hide_face, hide_hair = get_option(data, "HideFace") == true, get_option(data, "HideHair") == true
        if get_option(data, "Enable") ~= true or (not hide_face and not hide_hair) then return end
        local address = quest_object_address(face)
        if not address or address == quest_object_address(owner) then return end
        local protected = {}
        for _, hash in ipairs({ 3471977595, 2156620752, 639293466, 1274174449, 1437951306 }) do
            local part = call(root, "getPartsObject", hash)
            local part_address = quest_object_address(part)
            if part_address then protected[part_address] = true end
        end
        if protected[address] then return end
        state.visibility_face = address
        state.visibility_protected = protected
        state.visibility_hide_face, state.visibility_hide_hair = hide_face, hide_hair
        state.visibility_options = { Enable = data.Enable, HideFace = data.HideFace, HideHair = data.HideHair }
        state.visibility_deadline = os.clock() + 60
        state.visibility_next = nil
        state.visibility_pending = true
        state.visibility = { status = "waiting for native visibility readback", checks = 0,
            writes = 0, repairs = 0, face_address = address, child_meshes = 0, zero_material_meshes = 0 }
    end

     
    function guard.update(action, state)
        if not state.visibility_pending then return end
        if not config.enabled or scene_transition.active or state.generation ~= scene_generation then
            return guard.stop(state, "visibility cancelled by lifecycle")
        end
        local now, info = os.clock(), state.visibility
        if now > state.visibility_deadline or info.checks >= max_checks then
            return guard.stop(state, "visibility check budget ended")
        end
        if state.visibility_next and now < state.visibility_next then return end
        state.visibility_next = now + interval
        local options = state.visibility_options
        if get_option(options, "Enable") ~= true
            or (get_option(options, "HideFace") == true) ~= state.visibility_hide_face
            or (get_option(options, "HideHair") == true) ~= state.visibility_hide_hair then
            return guard.stop(state, "original visibility options changed")
        end
        local phase, mot_phase = tonumber(field(action, "_Phase")), tonumber(field(action, "_MotPhase"))
        if (phase ~= 1 and phase ~= 2 and phase ~= 3) or (mot_phase ~= 1 and mot_phase ~= 2) then
            return guard.stop(state, "visibility native phase ended")
        end
        local motion = field(action, "_NpcMotionComponent")
        local owner = motion and get_game_object_quiet(motion)
        local creator, player = field(action, "_NpcVisualCreator"), field(action, "_Chara")
        if quest_object_address(owner) ~= state.owner_address or quest_object_address(motion) ~= state.motion_address
            or not same_runtime_object(owner, get_game_object_quiet(creator))
            or get_component(owner, "app.HunterCharacter")
            or (player and same_runtime_object(owner, get_game_object_quiet(player))) then
            return guard.stop(state, "visibility owner changed")
        end
        local root = edit_root_for(owner)
        local face = root and call(root, "getPartsObject", 935285574)
        if quest_object_address(face) ~= state.visibility_face then
            return guard.stop(state, "visibility Face slot changed")
        end
        info.checks, info.last_check = info.checks + 1, now
        local nodes, materials, child_meshes, zero_meshes, writes, unreadable = 0, 0, 0, 0, 0, 0
        local visited = {}

        local function hide_mesh(part, is_face)
            local mesh = get_component(part, "via.render.Mesh")
            if not mesh then return end
            if not is_face then child_meshes = child_meshes + 1 end
            local count = tonumber(call(mesh, "get_MaterialNum"))
            if not count or count < 0 or count > max_materials or count % 1 ~= 0 then
                error("invalid native visibility material count")
            end
            materials = materials + count
            if materials > max_materials then error("native visibility total material budget exceeded") end
            if count == 0 then zero_meshes = zero_meshes + 1 end
            for index = 0, count - 1 do
                local enabled = call(mesh, "getMaterialsEnable", index)
                if enabled == true then
                    local ok, message = call_any(mesh, "setMaterialsEnable", index, false)
                    if not ok then error(tostring(message)) end
                    if call(mesh, "getMaterialsEnable", index) ~= false then
                        error("native visibility write did not read back hidden")
                    end
                    writes = writes + 1
                elseif enabled ~= false then
                    unreadable = unreadable + 1
                end
            end
        end

        local function walk(part, is_face, depth)
            nodes = nodes + 1
            if nodes > max_nodes or depth > 8 then error("native visibility hierarchy budget exceeded") end
            local address = quest_object_address(part)
            if not address or visited[address] then error("invalid native visibility child identity") end
            visited[address] = true
             
            if address == state.owner_address or state.visibility_protected[address] then return end
            local name = get_game_object_name_quiet(part)
            if not is_face and type(name) == "string" and name:match("^ch0[23]_%d") then return end
            if not is_face or state.visibility_hide_face then hide_mesh(part, is_face) end
            if not state.visibility_hide_hair then return end
            local transform = get_transform(part)
            local child = transform and call(transform, "get_Child")
            local siblings = 0
            while child do
                siblings = siblings + 1
                if siblings > max_nodes then error("native visibility sibling budget exceeded") end
                local object = get_game_object_quiet(child)
                if not object then error("native visibility child unavailable") end
                walk(object, false, depth + 1)
                child = call(child, "get_Next")
            end
        end

        walk(face, true, 0)
        info.nodes, info.child_meshes, info.zero_material_meshes = nodes, child_meshes, zero_meshes
        info.materials = materials
        info.unreadable_materials = unreadable
        info.writes = info.writes + writes
        if writes > 0 then
            info.repairs, info.last_repair = info.repairs + 1, now
        end
        info.status = unreadable > 0 and "waiting for native material visibility readback"
            or zero_meshes > 0 and "waiting for native child materials"
            or "native visibility checked; watching active result"
    end

    return guard
end

local function install_quest_result_hooks()
    local states, state_order = {}, {}
    local paused = false
    local report_key = "quest_result"
    local quest = { calls = 0, attempts = 0, succeeded = 0, errors = 0, face_attempts = 0, hide_attempts = 0,
        recent_results = {},
        face_traces = {}, trace_samples = 0, trace_errors = 0, face_relays = {}, relay_errors = 0,
        visibility_errors = 0 }
    performance[report_key] = quest

    local function field(object, name)
        local ok, value = probe_field_quiet(object, name)
        if ok then return value end
    end

    local function call(object, name, ...)
        local ok, value = call_any(object, name, ...)
        if ok then return value end
    end

     
    local trace_offsets = { 0, 0, 0.15, 0.4, 0.8, 1.5, 3, 5 }
    local trace_joints = { "L_UpEyeLidJ_LOD02", "R_UpEyeLidJ_LOD02",
        "C_upLip_LOD02", "C_loLip_LOD02", "C_Jaw_LOD02" }

    local function vector_snapshot(value)
        if not value then return end
        local ok, result = pcall(function()
            local item = { x = tonumber(value.x), y = tonumber(value.y), z = tonumber(value.z) }
             
            local has_w, w = pcall(function() return value.w end)
            if has_w then item.w = tonumber(w) end
            return item
        end)
        if ok then return result end
    end

    local function joint_snapshot(transform, name)
        local joint = transform and call(transform, "getJointByName", name)
        local item = { present = joint ~= nil }
        if not joint then return item end
        item.valid = tostring(call(joint, "get_Valid"))
        for _, property in ipairs({ "LocalPosition", "LocalRotation", "LocalScale",
            "BaseLocalPosition", "BaseLocalRotation", "BaseLocalScale" }) do
            item[property] = vector_snapshot(call(joint, "get_" .. property))
        end
        return item
    end

    local function motion_snapshot(motion, with_layers)
        local item = { object = tostring(motion) }
        if not motion then return item end
        for _, property in ipairs({ "Enabled", "EnabledConstraints", "EnabledJointExpression" }) do
            item[property] = tostring(call(motion, "get_" .. property))
        end
        if not with_layers then return item end
        item.joint_map = tostring(call(motion, "get_JointMap"))
        item.joints_constructed = tostring(call(motion, "get_JointsConstructed"))
        item.joint_count = tonumber(call(motion, "get_JointCount"))
        local layers = call(motion, "get_Layer")
        local count = tonumber(layers and call(layers, "get_Count")) or 0
        item.layer_count, item.layers = count, {}
        for index = 0, math.min(count, 12) - 1 do
            local layer = call(layers, "get_Item", index)
            local entry = { index = index }
            for _, property in ipairs({ "Frame", "MotionBankID", "MotionID", "BlendRate", "Speed",
                "Enabled", "Running", "StopUpdate", "UpdateRootOnly", "AnimatedJointCount" }) do
                entry[property] = tostring(layer and call(layer, "get_" .. property))
            end
            item.layers[#item.layers + 1] = entry
        end
        return item
    end

    local function edit_root_for(object)
        local root = object and get_component(object, "app.CharacterEditRegionRoot")
        if root then return root, "root" end
        local region = object and get_component(object, "app.CharacterEditRegion")
        return region and call(region, "getRoot"), region and "region.getRoot" or "missing"
    end

    local face_relay = make_quest_face_relay(field, call, edit_root_for, quest)
    local visibility_guard = make_quest_visibility_guard(field, call, edit_root_for)

     
     
    local function face_trace_snapshot(action, state, stage)
        local motion = field(action, "_NpcMotionComponent")
        local owner = motion and get_game_object_quiet(motion)
        local root = edit_root_for(owner)
        local expected_face = root and call(root, "getPartsObject", 935285574)
        local bind_part = root and call(root, "getPartsObject", state.trace_bind_hash)
        local driver = bind_part and get_component(bind_part, "via.motion.Motion")
        local driver_kind = driver and "via.motion.Motion" or "via.motion.ChildSecondary"
        driver = driver or (bind_part and get_component(bind_part, driver_kind))
        local driver_owner = driver and get_game_object_quiet(driver)
        local bind_root, route = edit_root_for(driver_owner)
        local source_face = bind_root and call(bind_root, "getPartsObject", 935285574)
        local source_transform = source_face and get_transform(source_face)
        local target_transform = driver_owner and get_transform(driver_owner)
        local item = {
            stage = stage, time = os.clock(), offset = os.clock() - state.face_trace.started,
            phase = tonumber(field(action, "_Phase")), mot_phase = tonumber(field(action, "_MotPhase")),
            elapsed = tonumber(field(action, "_RawTotalElapsedSecond")),
            owner = tostring(owner), owner_root = tostring(root), expected_face = tostring(expected_face),
            bind_part = tostring(bind_part), driver = tostring(driver), driver_kind = driver_kind,
            driver_owner = tostring(driver_owner), bind_route = route, bind_root = tostring(bind_root),
            source_face = tostring(source_face), source_name = get_game_object_name_quiet(source_face),
            roots_agree = root ~= nil and bind_root ~= nil and same_runtime_object(root, bind_root),
            faces_agree = expected_face ~= nil and source_face ~= nil and same_runtime_object(expected_face, source_face),
            driver_unchanged = driver ~= nil and state.face_bind_driver_address ~= nil
                and quest_object_address(driver) == state.face_bind_driver_address,
            joints = {}, binding_motion = motion_snapshot(driver, driver_kind == "via.motion.Motion")
        }
        local face_motion = source_face and get_component(source_face, "via.motion.Motion")
        item.face_motion = motion_snapshot(face_motion, true)
        local controller = source_face and get_component(source_face, "app.FacialController")
        item.facial_controller = { object = tostring(controller) }
        if controller then
            for _, property in ipairs({ "_IsSetupDone", "_FaceObj", "_Motion", "_ParentObj",
                "_FacialMode", "_CurrentMotionSeqLayerNo", "_SeqMotionID", "_SeqMotionBankID",
                "_CurrentLodLevel", "_IsEventObj", "_SusependReduceFacial" }) do
                item.facial_controller[property] = tostring(field(controller, property))
            end
        end
        for _, name in ipairs(trace_joints) do
            item.joints[name] = { source = joint_snapshot(source_transform, name),
                target = joint_snapshot(target_transform, name) }
        end
         
        if expected_face and not item.faces_agree then
            item.expected_face_joints = {}
            local transform = get_transform(expected_face)
            for _, name in ipairs(trace_joints) do item.expected_face_joints[name] = joint_snapshot(transform, name) end
        end
        return item
    end

    local function stop_face_trace(state, reason)
        state.trace_pending = nil
        if state.face_trace and state.face_trace.status == "sampling" then state.face_trace.status = reason end
    end

    local function sample_face_trace(action, state, stage)
        if not state.trace_pending then return end
        local trace = state.face_trace
        state.trace_checks = state.trace_checks + 1
        if not config.enabled or scene_transition.active or state.generation ~= scene_generation then
            stop_face_trace(state, "cancelled by lifecycle")
            return
        end
        if os.clock() - trace.started > 6 or state.trace_checks > 3000 then
            stop_face_trace(state, "sample budget ended")
            return
        end
        if os.clock() - trace.started < trace_offsets[#trace.samples + 1] then return end
        local phase = tonumber(field(action, "_Phase"))
        local motion = field(action, "_NpcMotionComponent")
        local owner = motion and get_game_object_quiet(motion)
        local creator = field(action, "_NpcVisualCreator")
        local player = field(action, "_Chara")
        if (phase ~= 1 and phase ~= 2 and phase ~= 3) or quest_object_address(owner) ~= state.owner_address
            or quest_object_address(motion) ~= state.motion_address
            or not same_runtime_object(owner, get_game_object_quiet(creator))
            or get_component(owner, "app.HunterCharacter")
            or (player and same_runtime_object(owner, get_game_object_quiet(player))) then
            stop_face_trace(state, "action or owner changed")
            return
        end
        local ok, sample = pcall(face_trace_snapshot, action, state, stage)
        if not ok then
            trace.error = tostring(sample)
            quest.trace_errors = quest.trace_errors + 1
            stop_face_trace(state, "read failed")
            return
        end
        trace.samples[#trace.samples + 1] = sample
        quest.trace_samples = quest.trace_samples + 1
        if #trace.samples == #trace_offsets then stop_face_trace(state, "sampled") end
    end

    local function begin_face_trace(action, state, bind_hash)
        state.trace_bind_hash, state.trace_pending, state.trace_checks = bind_hash, true, 0
        state.face_trace = { action = state.key, owner = state.owner, body_id = state.body_id,
            generation = state.generation, started = os.clock(), status = "sampling", samples = {} }
        quest.face_traces[#quest.face_traces + 1] = state.face_trace
        if #quest.face_traces > 4 then table.remove(quest.face_traces, 1) end
        sample_face_trace(action, state, "before_face_api")
    end

     
    local function part_snapshot(part)
        local item = { object = tostring(part), name = get_game_object_name_quiet(part) }
        if not part then return item end
        local mesh = get_component(part, "via.render.Mesh")
        if not mesh then return item end
        item.mesh = tostring(mesh)
        item.enabled = tostring(call(mesh, "get_Enabled"))
        item.materials = {}
        local count = tonumber(call(mesh, "get_MaterialNum")) or 0
        item.material_count = count
        for index = 0, math.min(count, 128) - 1 do
            item.materials[#item.materials + 1] = {
                name = tostring(call(mesh, "getMaterialName", index)),
                enabled = tostring(call(mesh, "getMaterialsEnable", index))
            }
        end
        return item
    end

     
    local function snapshot(action, motion)
        local result = {
            phase = tonumber(field(action, "_Phase")),
            mot_phase = tonumber(field(action, "_MotPhase")),
            first_update = tostring(field(action, "_IsFirstUpdate")),
            elapsed = tonumber(field(action, "_RawTotalElapsedSecond"))
        }
        if motion then
            result.motion = tostring(motion)
            local owner = get_game_object_quiet(motion)
            local transform = owner and get_transform(owner)
            result.owner = tostring(owner)
            for _, name in ipairs({ "Position", "LocalPosition" }) do
                local value = transform and call(transform, "get_" .. name)
                if value then
                    local ok, xyz = pcall(function() return { x = value.x, y = value.y, z = value.z } end)
                    if ok then result[name] = xyz end
                end
            end
            local skeleton = owner and get_component(owner, "via.motion.CustomSkeleton")
            local holder = skeleton and call(skeleton, "get_SkeletonResourceHandle")
             
            result.resource_path = tostring(call(holder, "get_ResourcePath"))
            result.custom_skeleton = tostring(skeleton)
            result.auto_apply = tostring(call(skeleton, "get_AutoApply"))
            local edit_root = get_component(owner, "app.CharacterEditRegionRoot")
            local edit_region = get_component(owner, "app.CharacterEditRegion")
            result.edit_root_present = edit_root ~= nil
            result.edit_region_present = edit_region ~= nil
            edit_root = edit_root or (edit_region and call(edit_region, "getRoot"))
            result.bone_api_root = tostring(edit_root)
            result.bone_api_slots = {}
            for label, hash in pairs({ main = 4175418299, face = 935285574, chest = 3471977595 }) do
                local part = edit_root and call(edit_root, "getPartsObject", hash)
                result.bone_api_slots[label] = {
                    object = tostring(part), name = get_game_object_name_quiet(part),
                    mesh = tostring(part and get_component(part, "via.render.Mesh"))
                }
            end
            for _, name in ipairs({ "RootMotion", "RootScaleDisabled", "JointsConstructed", "SkeletonConstructCount", "JointCount" }) do
                result[name] = tostring(call(motion, "get_" .. name))
            end
            for _, name in ipairs({ "RootMotionTranslation", "OriginalRootMotionTranslation" }) do
                local value = call(motion, "get_" .. name)
                if value then
                    local ok, xyz = pcall(function() return { x = value.x, y = value.y, z = value.z } end)
                    if ok then result[name] = xyz end
                end
            end
        end
        local creator = field(action, "_NpcVisualCreator")
        local controller = creator and call(creator, "get_CharaMakeController")
        if controller then
            result.parts = {}
            for label, hash in pairs({ main = 4175418299, face = 935285574, chest = 3471977595 }) do
                result.parts[label] = part_snapshot(call(controller, "getPartsObject(System.UInt32)", hash))
            end
        end
        return result
    end

    local function remember(state, status)
        state.status = status
        quest.last_status = status
         
        if not state.summary then
            state.summary = { action = state.key, scene_generation = state.generation, started = state.started }
            quest.recent_results[#quest.recent_results + 1] = state.summary
            if #quest.recent_results > 8 then table.remove(quest.recent_results, 1) end
        end
        local summary = state.summary
        summary.time, summary.status = os.clock(), status
        summary.owner, summary.npc_name, summary.body_id = state.owner, state.npc_name, state.body_id
        summary.owner_address, summary.motion_address = state.owner_address, state.motion_address
        summary.bone_ok, summary.face_status = state.bone_ok, state.face_status
        summary.face_checks, summary.face_attempts = state.face_checks or 0, state.face_attempts or 0
        summary.hide_attempts, summary.hide_status = state.hide_attempts or 0, state.hide_status
        summary.phase, summary.mot_phase = state.face_phase, state.face_mot_phase
        summary.native_update_result = state.native_update_result
        summary.visibility = state.visibility
        summary.variant_ok = state.variant and state.variant.ok
        local item = {
            time = os.clock(), mode = report_key, status = status,
            action = state.key, scene_generation = state.generation,
            attempts = state.attempts, owner = state.owner,
            owner_address = state.owner_address, motion_address = state.motion_address,
            native_after = state.native_after, before = state.before, after = state.after,
            next_callback = state.next_callback, settled = state.settled, variant = state.variant,
            body_id = state.body_id, actual_resource = state.actual_resource,
            face_status = state.face_status, face_after = state.face_after,
            face_checks = state.face_checks, face_ready = state.face_ready,
            face_bind_driver = state.face_bind_driver,
            face_bind_driver_address = state.face_bind_driver_address,
            hide_attempts = state.hide_attempts, hide_status = state.hide_status,
            visibility = state.visibility,
            face_trace_started = state.face_trace and state.face_trace.started
        }
        quest.last_result = item
        remember_operation(item)
        record_event(report_key, status)
    end

    local function new_state(key)
        local state = { key = key, generation = scene_generation, attempts = 0, checks = 0,
            finished = false, started = os.clock(), diagnostics = config.debug_log == true }
        if not states[key] then
            state_order[#state_order + 1] = key
            if #state_order > 16 then
                local oldest = table.remove(state_order, 1)
                if states[oldest] then
                    stop_face_trace(states[oldest], "state budget evicted")
                    face_relay.stop(states[oldest], "state budget evicted")
                    visibility_guard.stop(states[oldest], "state budget evicted")
                    states[oldest].face_data = nil
                    states[oldest].face_status = "state budget evicted"
                    remember(states[oldest], "state budget evicted")
                end
                states[oldest] = nil
            end
        end
        states[key] = state
        return state
    end

    local function process(action, state)
        if not config.enabled or scene_transition.active then return end
        if state.finished or state.generation ~= scene_generation then return end
        local phase = tonumber(field(action, "_Phase"))
        if phase ~= 0 then return end
        local creator = field(action, "_NpcVisualCreator")
        if not creator or call(creator, "get_IsCreated") ~= true then return end

         
        local motion = field(action, "_NpcMotionComponent")
        local owner = motion and get_game_object_quiet(motion)
        if not owner or not same_runtime_object(owner, get_game_object_quiet(creator)) then
            state.finished = true
            remember(state, "creator and NPC Motion owner do not agree")
            return
        end
        state.owner_address, state.motion_address = quest_object_address(owner), quest_object_address(motion)
        if not state.owner_address or not state.motion_address then
            state.finished = true
            remember(state, "NPC identity unavailable; no skeleton write")
            return
        end
        local player = field(action, "_Chara")
        if get_component(owner, "app.HunterCharacter")
            or (player and same_runtime_object(owner, get_game_object_quiet(player))) then
            state.finished = true
            remember(state, "player owner rejected before any skeleton write")
            return
        end
        local ready, reason = probe_candidate_bone_state(owner, "quest_result_owner")
        if not ready or not same_runtime_object(ready.motion, motion) then
            state.finished = true
            remember(state, "native creator completed but skeleton not ready: " .. tostring(reason))
            return
        end
        local controller = call(creator, "get_CharaMakeController")
        if not controller or call(controller, "isFinishPartsSetup") ~= true then
            state.finished = true
            remember(state, "native creator completed but parts not ready; no late retry")
            return
        end
        local parts, chest = {}, nil
        for index = 0, 5 do
            local part = call(controller, "getPartsObject(app.ArmorDef.ARMOR_PARTS)", index)
            if part then parts[#parts + 1] = part end
            if index == 1 then chest = part end
        end
        local name = get_game_object_name_quiet(chest)
        local cache = new_event_cache_entry()
        local resolution, match_status = resolve_target(creator, owner, cache, {
            chest_state = {
                chest_object = chest, chest_name = name, chest_body_id = body_id_from_object_name(name),
                source = report_key, cache_route = report_key
            }, extra_roots = parts, disable_session_cache = true
        })
        state.finished = true
        if not resolution then
            remember(state, "no configured outfit: " .. tostring(match_status))
            return
        end
        state.owner = tostring(owner)
        state.npc_name = get_game_object_name_quiet(owner)
        state.body_id = resolution.body_id
        state.before = state.diagnostics and snapshot(action, motion) or { motion = tostring(motion) }
        state.attempts = 1
        quest.attempts = quest.attempts + 1
        local ok, status, _, _, _, variant, variant_ok = inspect_character(
            creator, report_key, resolution, cache, {
                root_obj = owner, extra_roots = parts, defer_report = true,
                expected_readiness_signature = ready.signature
            }
        )
        if state.diagnostics then
            state.after = snapshot(action, motion)
            state.sample_next = true
            state.sample_settled_at = os.clock() + 0.25
        end
        state.variant = { ok = variant_ok == true, status = tostring(variant) }
        state.bone_ok = ok == true
        local holder = call(ready.custom_skeleton, "get_SkeletonResourceHandle")
        state.actual_resource = tostring(call(holder, "get_ResourcePath"))
        if ok then
            quest.succeeded = quest.succeeded + 1
            local data = load_bone_config(resolution.target.bone_system_body_id or resolution.body_id)
            local face_data = make_target_bone_data(data, resolution.target)
            if type(face_data) == "table" then
                 
                state.face_data = { FixBone = false }
                 
                state.face_deadline = os.clock() + 60
                state.face_checks = 0
                for _, name in ipairs({ "Enable", "HideFace", "HideHair", "HideSlinger", "BindFace", "BindPart", "DispOffOutDoorCookingHelm" }) do
                    state.face_data[name] = face_data[name]
                end
            end
        end
        remember(state, tostring(status))
        return state
    end

     
    local function prepare(action)
        quest.calls = quest.calls + 1
        local key = quest_object_address(action)
        if not key then return end
        local state = states[key]
        if state and state.generation ~= scene_generation then
            stop_face_trace(state, "scene generation changed")
            face_relay.stop(state, "scene generation changed")
            visibility_guard.stop(state, "scene generation changed")
            state.face_data = nil
            state.face_status = "scene generation changed; face wait cancelled"
            remember(state, state.status)
            state = nil
        end
        if state and state.finished then
            if state.sample_next then
                state.sample_next = false
                state.next_callback = snapshot(action, field(action, "_NpcMotionComponent"))
                remember(state, "next callback readback; " .. state.status)
            elseif state.sample_settled_at and os.clock() >= state.sample_settled_at then
                state.sample_settled_at = nil
                state.settled = snapshot(action, field(action, "_NpcMotionComponent"))
                remember(state, "settled readback; " .. state.status)
            end
            if state.face_data or state.trace_pending or state.relay_enabled or state.visibility_pending then return state end
            return
        end
        state = state or new_state(key)
        if tonumber(field(action, "_Phase")) ~= 0 then
            state.finished = true
            remember(state, "WAIT exit not observed; no late skeleton write")
            return
        end
        state.checks = state.checks + 1
        if state.checks > 2400 or os.clock() - state.started > 15 then
            state.finished = true
            remember(state, "bounded WAIT budget exceeded; no late skeleton write")
            return
        end
        return process(action, state)
    end

    local function face_status(state, message, stop)
        if stop then state.face_data = nil end
        if state.face_status ~= message then
            state.face_status = message
            remember(state, state.status)
        end
    end

     
    local function hide_ready_face(owner, state)
        local data = state.face_data
        if state.hide_attempts or data.Enable == false or data.HideFace ~= true then return end
        local hide_data = {}
        for name, value in pairs(data) do hide_data[name] = value end
        hide_data.BindFace = false
        state.hide_attempts = 1
        quest.hide_attempts = quest.hide_attempts + 1
        local ok, message = pcall(API.fix_bone, owner, hide_data, nil)
        state.hide_status = ok and "hide-only API returned; binding still pending" or tostring(message)
        if not ok then quest.errors = quest.errors + 1 end
        remember(state, state.status)
    end

     
     
    local function finish_face(action, state)
        local face_data = state.face_data
        if not face_data then return end
        if state.generation ~= scene_generation then
            face_status(state, "scene generation changed; face wait cancelled", true)
            return
        end
        local now = os.clock()
        if state.face_checks >= 1200 or now > state.face_deadline then
            face_status(state, "face slot wait budget exceeded; no late retry", true)
            return
        end
        local phase = tonumber(field(action, "_Phase"))
        local mot_phase = tonumber(field(action, "_MotPhase"))
        if state.face_phase ~= phase or state.face_mot_phase ~= mot_phase then state.next_face_probe = nil end
        state.face_phase, state.face_mot_phase = phase, mot_phase
        if phase == 0 and not state.face_wait_confirmed then
            face_status(state, "waiting for native WAIT exit", false)
            return
        end
        if phase ~= 1 and phase ~= 2 and phase ~= 3 then
            face_status(state, "native result phase ended; face wait cancelled", true)
            return
        end
        state.face_wait_confirmed = true
         
        if mot_phase == 0 then
            face_status(state, "waiting for native motion setup", false)
            return
        end
        if mot_phase ~= 1 and mot_phase ~= 2 then
            face_status(state, "unsupported native motion phase; face wait cancelled", true)
            return
        end
        if state.next_face_probe and now < state.next_face_probe then return end
        state.face_checks = state.face_checks + 1
         
        if state.summary then
            state.summary.face_checks, state.summary.face_last_check = state.face_checks, now
        end
         
        state.next_face_probe = state.face_checks >= 4 and now + 0.05 or nil
        local motion = field(action, "_NpcMotionComponent")
        local owner = motion and get_game_object_quiet(motion)
        local creator = field(action, "_NpcVisualCreator")
        if quest_object_address(owner) ~= state.owner_address or quest_object_address(motion) ~= state.motion_address
            or not same_runtime_object(owner, get_game_object_quiet(creator)) then
            face_status(state, "native owner changed; no cross-object face write", true)
            return
        end
        local player = field(action, "_Chara")
        if get_component(owner, "app.HunterCharacter")
            or (player and same_runtime_object(owner, get_game_object_quiet(player))) then
            face_status(state, "player owner rejected", true)
            return
        end
        if state.diagnostics and not state.native_after then state.native_after = snapshot(action, motion) end
        if call(motion, "get_JointsConstructed") ~= true then
            face_status(state, "waiting for constructed NPC joints", false)
            return
        end
        local edit_root = get_component(owner, "app.CharacterEditRegionRoot")
        local edit_region = not edit_root and get_component(owner, "app.CharacterEditRegion")
        edit_root = edit_root or (edit_region and call(edit_region, "getRoot"))
        local face = edit_root and call(edit_root, "getPartsObject", 935285574)
        local mesh = face and get_component(face, "via.render.Mesh")
        if not mesh or (tonumber(call(mesh, "get_MaterialNum")) or 0) <= 0 then
            face_status(state, "waiting for stock BoneSystem Face slot and materials", false)
            return
        end
        local chest = call(edit_root, "getPartsObject", 3471977595)
        local bind_hashes = { 3471977595, 2156620752, 639293466, 1274174449 }
        local bind_hash = bind_hashes[tonumber(face_data.BindPart) or 1]
        local bind_part = bind_hash and call(edit_root, "getPartsObject", bind_hash)
        if not chest or (face_data.BindFace == true and not bind_part) then
            hide_ready_face(owner, state)
            face_status(state, "waiting for stock BoneSystem Chest/bind slot", false)
            return
        end
        if face_data.BindFace == true then
            local bind_motion = get_component(bind_part, "via.motion.Motion")
                or get_component(bind_part, "via.motion.ChildSecondary")
            if not bind_motion then
                hide_ready_face(owner, state)
                face_status(state, "waiting for stock BoneSystem binding Motion/ChildSecondary", false)
                return
            end
            state.face_bind_driver_address = quest_object_address(bind_motion)
            if not state.face_bind_driver_address then
                face_status(state, "binding identity unavailable; face wait cancelled", true)
                return
            end
            state.face_bind_driver = tostring(bind_motion)
        end
        if state.diagnostics then state.face_ready = snapshot(action, motion) end
        if state.diagnostics and face_data.BindFace == true then
             
            local traced, trace_error = pcall(begin_face_trace, action, state, bind_hash)
            if not traced then
                quest.trace_errors = quest.trace_errors + 1
                if state.face_trace then state.face_trace.error = tostring(trace_error) end
                stop_face_trace(state, "trace initialization failed")
            end
        end
         
        state.face_data = nil
        state.face_attempts = (state.face_attempts or 0) + 1
        quest.face_attempts = quest.face_attempts + 1
        local ok, message = pcall(API.fix_bone, owner, face_data, nil)
        state.face_status = ok and "face-only API returned; check material readback" or tostring(message)
        if not ok then quest.errors = quest.errors + 1 end
        if ok and face_data.Enable ~= false and face_data.BindFace == true and face_relay.available then
            face_relay.arm(state, face, bind_part, bind_hash)
        end
        if ok then visibility_guard.arm(state, face, face_data, edit_root, owner) end
        if state.diagnostics then state.face_after = snapshot(action, motion) end
        if not ok then stop_face_trace(state, "face API failed") end
        if state.diagnostics then state.sample_settled_at = os.clock() + 0.25 end
        remember(state, state.status)
    end

    local function record_error(action, message)
        quest.errors = quest.errors + 1
        local key = quest_object_address(action)
        if not key then
            quest.last_status = "caught error without action identity: " .. tostring(message)
            return
        end
        local state = states[key] or new_state(key)
        state.finished = true
        state.face_data = nil
        face_relay.stop(state, "result callback failed")
        visibility_guard.stop(state, "result callback failed")
        stop_face_trace(state, "result callback failed")
        state.sample_next, state.sample_settled_at = nil, nil
        remember(state, "caught error: " .. tostring(message))
    end

    local function storage_or_nil()
        local ok, storage = pcall(thread.get_hook_storage)
        if ok then return storage end
    end

     
    local function native_update_result(retval)
        local value = type(retval) == "number" and retval or nil
        if not value and sdk.to_int64 then
            local ok, raw = pcall(sdk.to_int64, retval)
            if ok then value = math.tointeger(raw) end
        end
        return value and (value & 0xffffffff) or nil
    end

    local type_def = safe_sdk_type("app.PlayerCommonAction.cQuestClearBase")
    local update, exit_method
    local methods_ok = pcall(function()
        update = type_def and type_def:get_method("doUpdate")
        exit_method = type_def and type_def:get_method("doExit")
    end)
    if methods_ok and update and exit_method and thread and thread.get_hook_storage then
        local ok, err = pcall(function()
            sdk.hook(update, function(args)
                local storage = storage_or_nil()
                if not storage then return end
                storage.bsfn_quest_action = nil
                storage.bsfn_quest_state = nil
                if not config.enabled or scene_transition.active then
                     
                    if not paused then
                        paused = true
                        for _, state in pairs(states) do
                            stop_face_trace(state, "result suspended")
                            face_relay.stop(state, "result suspended")
                            visibility_guard.stop(state, "result suspended")
                            if state.face_data then
                                face_status(state, "result suspended; face wait cancelled", true)
                            end
                        end
                    end
                    return
                end
                paused = false
                local converted, action = pcall(sdk.to_managed_object, args[2])
                if not converted or not action then return end
                local success, state = pcall(prepare, action)
                if not success then
                    record_error(action, state)
                elseif state then
                    storage.bsfn_quest_action = action
                    storage.bsfn_quest_state = state
                end
            end, function(retval)
                local storage = storage_or_nil()
                if not storage then return retval end
                local action, state = storage.bsfn_quest_action, storage.bsfn_quest_state
                storage.bsfn_quest_action, storage.bsfn_quest_state = nil, nil
                if action and state then
                    state.native_update_result = native_update_result(retval)
                    if state.native_update_result == 1 then
                        if state.face_data then state.face_status = "native update ended before face completion" end
                        state.face_data = nil
                        state.sample_next, state.sample_settled_at = nil, nil
                        face_relay.stop(state, "native update ended")
                        visibility_guard.stop(state, "native update ended")
                        stop_face_trace(state, "native update ended")
                        remember(state, "native update returned END; " .. tostring(state.status))
                        return retval
                    end
                    if config.enabled and not scene_transition.active then
                        local ok, message = pcall(finish_face, action, state)
                        if not ok then record_error(action, message) end
                        if ok then
                             
                            local visible, visibility_error = pcall(visibility_guard.update, action, state)
                            if not visible then
                                quest.visibility_errors = quest.visibility_errors + 1
                                if state.visibility then state.visibility.error = tostring(visibility_error) end
                                visibility_guard.stop(state, "visibility read/write failed; stopped for this action")
                            end
                            face_relay.queue(state)
                            local sampled, sample_error = pcall(sample_face_trace, action, state, "after_native_update")
                            if not sampled then
                                quest.trace_errors = quest.trace_errors + 1
                                if state.face_trace then state.face_trace.error = tostring(sample_error) end
                                stop_face_trace(state, "read failed")
                            end
                        end
                    else
                        face_status(state, "result suspended in original callback", true)
                        face_relay.stop(state, "result suspended in original callback")
                        visibility_guard.stop(state, "result suspended in original callback")
                        stop_face_trace(state, "result suspended in original callback")
                    end
                end
                return retval
            end)
            sdk.hook(exit_method, function(args)
                local converted, action = pcall(sdk.to_managed_object, args[2])
                if not converted or not action then return end
                local key = quest_object_address(action)
                if not key then return end
                local state = states[key]
                if state then
                    if state.face_data then state.face_status = "action exited before face completion" end
                    state.face_data = nil
                    face_relay.stop(state, "action exited")
                    visibility_guard.stop(state, "action exited")
                    stop_face_trace(state, "action exited")
                    remember(state, "action exited; " .. tostring(state.status))
                    states[key] = nil
                    for i = #state_order, 1, -1 do
                        if state_order[i] == key then table.remove(state_order, i) end
                    end
                end
            end, function(retval) return retval end)
        end)
        hook_state.quest_result = ok and "installed: bounded face-slot readiness; result-only facial relay before LockScene; no normal-scene scan" or tostring(err)
    else
        hook_state.quest_result = "unavailable: native action methods or hook storage missing"
    end
end
install_quest_result_hooks()
