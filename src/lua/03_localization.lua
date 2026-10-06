-- =============================================================================
-- 材质常量、统计与多语言
-- =============================================================================
-- 界面字典集中维护；统计字段保持兼容现有报告和离线检查。

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
