-- =============================================================================
-- 全屏任务菜单暂停
-- =============================================================================
-- 进入任务列表后锁存暂停，直到 GUI050000 完全退出；冻结计时而不清空人物。

-- 缓存寿命按实际运行时间计算，打开菜单不会把仍在场的 NPC 判定为超时。
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

-- NPC 对话本身不是全屏菜单；只在任务列表首次激活后锁存到整个 GUI 消失。
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
