-- =============================================================================
-- 配置常量与运行时状态
-- =============================================================================
-- 保持稳定版默认值；运行时缓存不写入套装配置，索引由脚本自行维护。

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
    apply_delay = 2.0, -- legacy compatibility; real readiness replaces the fixed delay
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
