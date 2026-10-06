-- =============================================================================
-- 普通场景龙人腿部 IK：等待目标骨链真正提交后修正当前实例
-- =============================================================================
-- 沿用注册表和加载暂停；成功后不再检查，不进入艺术馆或结算分支。
-- 新建 holder/layer 不进入 Lua 包装缓存；原生模块在一次调用内持有、交付并释放。
-- 这里只缓存函数，不缓存场景对象或资源，也不新增回调。
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

    -- get_address 是 REFramework 的 Lua 绑定，不是可用 obj:call 反射的游戏方法。
    -- tostring(obj) 是 Lua 包装身份，跨帧可变；不可把它当作原生指针的回退值。
    local function native_address(object)
        if not object then return nil end
        local ok, value = pcall(function() return object:get_address() end)
        if ok and type(value) == "number" and value > 0 and value % 1 == 0 then return value end
        return nil
    end

    -- 报告只存字符串和计数，最多十六条，不保留场景对象或主动写磁盘。
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

    -- 原始就绪样本已经由普通路径最终重取并校验；此处不额外遍历场景或部件树。
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
        -- 延后任务只保存标量身份；场景对象仍由原有 registered 缓存统一管理。
        return {
            profile = profile, candidate = candidate_address,
            component = component_address, motion = motion_address,
            skeleton = skeleton_address, desired = normalized(desired),
            original_ik_path = normalized(path), generation = scene_generation,
            dictionary = dictionary_generation, checks = 0, next_check = 0
        }
    end

    -- 检查当前实例的完整父链，不能只凭目标文件名推断它一定属于人类骨架。
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

    -- setter 只换资源并标记待构建；不能在 fix_bone 返回的同一调用里判定永久缺骨。
    function helper.finish(plan, bone_ok, entry)
        if not plan or not bone_ok then return end
        entry.nonhuman_ik_pending = plan
        entry.nonhuman_ik = { profile = plan.profile, status = "pending", detail = "waiting for native skeleton commit" }
    end

    -- 骨链十二次、setup 四次为短时检查额度；未就绪后降频，成功或身份失效才结束。
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
            -- 已验证的同一实例交给原生辅助器；锁忙沿用原节流，其他失败不重复写入。
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
