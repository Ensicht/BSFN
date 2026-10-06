-- =============================================================================
-- 龙人外观模型前掌：换骨完成期的一次性实例绑定修正
-- =============================================================================
-- 不改 root 姿态、IK、共享资源或既有约束层；没有新 Hook/帧回调。
-- 骨架后续独立重建可能恢复原生映射，当前实现不添加轮询来维持这四项。
local nonhuman_forefoot = (function()
    local helper = {}
    -- 前二十次短时确认之后按普通检查间隔降频；只在当前注册对象存活且近期更新时查询。
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

    -- 与 IK/手指共用已缓存的原生分类，不能按人物名字或身体高度猜龙人。
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

    -- 只看当前 NPC 的直接子对象，最多 32 个；等待时限频，成功后不再访问。
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

    -- 原生输出表不覆盖所有约束类型，不能仅凭空输出表认定没有写入。
    -- DLL 在场景锁内读取已验证格式；SC 默认允许共存，不代表已确认没有脚骨写入。
    -- 仍拦截已识别的脚骨写入、未知格式和独立换骨，不修改作者原有约束。
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
            -- 空层由原生检查确认；仍继续检查后续层，不能掩盖未加载或写脚骨的约束。
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
            -- 当前包装对象保持到调用结束，不把 Joint/map 地址保存到任何缓存。
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
