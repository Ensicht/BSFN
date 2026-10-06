#pragma once
#include <array>
#include <cstdint>
#include <cstring>
#include <initializer_list>
#include <reframework/API.h>

namespace bsfn_resource {
using Object = REFrameworkManagedObjectHandle;
using Resource = REFrameworkResourceHandle;
enum Status {
    Applied = 0, Busy = 2, BadArguments = 10, UnsupportedHost = 11,
    BadOwner = 12, MissingApi = 13, BadSignature = 14, MissingContext = 15,
    ResourceFailed = 16, HolderFailed = 17, LayerFailed = 18, InvokeFailed = 19,
    ReadbackFailed = 20, CountChanged = 21, RollbackFailed = 22, Unexpected = 23,
    CleanupFailed = 24
};
constexpr const char* ik_path = "Motion/NPC/Decorate/IkLeg/NpcIkLeg_Default.ikleg2";
constexpr const char* fingers_path = "BoneSystemForNPC/Constraints/WyverianPinky_DSG.jcns";
constexpr const char* layer_type = "via.motion.JointConstraintsLayer";

struct Diagnostic {
    const char* phase = "validate";
    const char* method = "none";
    int sdk_error = 0;
    bool exception = false, native_exception = false, failed = false;
    bool settings_read = false;
    uint8_t pause = 0, expected_pause = 0, timing = 0;
    double blend = 0;
    void enter(const char* stage) { if (!failed) { phase = stage; method = "none"; } }
};

// REF InvokeRet is a packed 128-byte value followed by the exception flag.
// Keep the buffer aligned too; the flag offset, not sizeof of a C++ union, is the ABI.
struct alignas(16) Result {
    std::array<unsigned char, 144> bytes{};
    template<class T> T get() const { T out{}; std::memcpy(&out, bytes.data(), sizeof(out)); return out; }
};

inline bool available(const REFrameworkSDKData* s) {
    return s && s->functions && s->tdb && s->type_definition && s->method &&
        s->managed_object && s->resource_manager && s->resource &&
        s->functions->get_tdb && s->functions->get_resource_manager &&
        s->tdb->find_type && s->tdb->find_method && s->type_definition->is_derived_from &&
        s->type_definition->create_instance && s->method->invoke && s->method->get_num_params &&
        s->method->get_params && s->method->get_return_type && s->method->is_static &&
        s->managed_object->is_managed_object && s->managed_object->get_type_definition &&
        s->managed_object->add_ref && s->managed_object->release &&
        s->resource_manager->create_resource && s->resource->create_holder &&
        s->resource->add_ref && s->resource->release;
}

struct References {
    const REFrameworkSDKData* sdk;
    bool cleanup_failed = false;
    void release(Object p) noexcept {
        if (p) try { sdk->managed_object->release(p); } catch (...) { cleanup_failed = true; }
    }
    void release(Resource p) noexcept {
        if (p) try { sdk->resource->release(p); } catch (...) { cleanup_failed = true; }
    }
};
template<class Handle> struct Pin {
    References& refs;
    Handle value = nullptr;
    explicit Pin(References& r) : refs(r) {}
    Pin(const Pin&) = delete;
    Pin& operator=(const Pin&) = delete;
    ~Pin() { refs.release(value); }
    void adopt(Handle p) { refs.release(value); value = p; }
    void acquire(Handle p) {
        if (p) add(p);
        refs.release(value);
        value = p;
    }
private:
    void add(Object p) { refs.sdk->managed_object->add_ref(p); }
    void add(Resource p) { refs.sdk->resource->add_ref(p); }
};

template<class Memory> class Operation {
    const REFrameworkSDKData* sdk;
    Memory& memory;
    References& refs;
    Diagnostic& diagnostic;
    REFrameworkTDBHandle tdb = nullptr;
    Object root, component;
    bool fingers;
    const char* component_type;
    const char* resource_type;
    const char* holder_type;
    REFrameworkMethodHandle get_asset{}, set_asset{}, get_count{}, set_count{}, get_layer{}, set_layer{};
    REFrameworkMethodHandle get_pause{}, set_pause{}, get_timing{}, set_timing{}, get_blend{}, set_blend{};
    Pin<Resource> resource_pin;
    Pin<Object> holder, layer;

    REFrameworkTypeDefinitionHandle type(const char* name) const { return sdk->tdb->find_type(tdb, name); }
    REFrameworkMethodHandle method(const char* owner, const char* name, const char* result,
                                  std::initializer_list<const char*> parameters) const {
        auto m = sdk->tdb->find_method(tdb, owner, name);
        auto returned = type(result);
        if (!m || !returned || sdk->method->is_static(m) ||
            sdk->method->get_num_params(m) != parameters.size() ||
            sdk->method->get_return_type(m) != returned) return nullptr;
        std::array<REFrameworkMethodParameter, 2> params{};
        unsigned count = 0;
        if (sdk->method->get_params(m, params.data(), sizeof(params), &count) != REFRAMEWORK_ERROR_NONE ||
            count != parameters.size()) return nullptr;
        unsigned i = 0;
        for (auto name_ : parameters) {
            auto expected = type(name_);
            if (!expected || params[i++].t != expected) return nullptr;
        }
        return m;
    }
    bool resolve() {
        tdb = sdk->functions->get_tdb();
        if (!tdb || !type(component_type) || !type("via.GameObject") || !type(holder_type)) return false;
        const char* owner = fingers ? layer_type : component_type;
        get_asset = method(owner, fingers ? "get_JointConstraintsAsset" : "get_IkLeg2Asset", holder_type, {});
        set_asset = method(owner, fingers ? "set_JointConstraintsAsset" : "set_IkLeg2Asset", "System.Void", {holder_type});
        if (!get_asset || !set_asset) return false;
        if (!fingers) return true;
        get_count = method(component_type, "getLayerCount", "System.Int32", {});
        set_count = method(component_type, "setLayerCount", "System.Void", {"System.Int32"});
        get_layer = method(component_type, "getLayer", layer_type, {"System.Int32"});
        set_layer = method(component_type, "setLayer", "System.Void", {"System.Int32", layer_type});
        get_pause = method(layer_type, "get_Pause", "System.Boolean", {});
        set_pause = method(layer_type, "set_Pause", "System.Void", {"System.Boolean"});
        get_timing = method(layer_type, "get_EnabledOverrideUpdateTiming", "System.Boolean", {});
        set_timing = method(layer_type, "set_EnabledOverrideUpdateTiming", "System.Void", {"System.Boolean"});
        get_blend = method(layer_type, "get_BlendRate", "System.Single", {});
        set_blend = method(layer_type, "set_BlendRate", "System.Void", {"System.Single"});
        return get_count && set_count && get_layer && set_layer && get_pause && set_pause &&
            get_timing && set_timing && get_blend && set_blend && type(layer_type);
    }
    bool is(Object object, const char* name) const {
        if (!memory.range(reinterpret_cast<uintptr_t>(object), 0x20, false) ||
            !sdk->managed_object->is_managed_object(object)) return false;
        auto actual = sdk->managed_object->get_type_definition(object), wanted = type(name);
        return actual && wanted && (actual == wanted || sdk->type_definition->is_derived_from(actual, wanted));
    }
    bool owner() const {
        if (!is(root, "via.GameObject") || !is(component, component_type)) return false;
        Object parent{};
        std::memcpy(&parent, reinterpret_cast<const unsigned char*>(component) + 0x10, sizeof(parent));
        return parent == root;
    }
    bool invoke(REFrameworkMethodHandle m, Object object, Result& result,
                std::initializer_list<uintptr_t> values = {}) const {
        std::array<void*, 2> args{};
        unsigned n = 0;
        for (auto value : values) args[n++] = reinterpret_cast<void*>(value);
        result = {};
        if (!diagnostic.failed) {
            const std::array<REFrameworkMethodHandle, 12> methods{get_asset, set_asset, get_count, set_count,
                get_layer, set_layer, get_pause, set_pause, get_timing, set_timing, get_blend, set_blend};
            const char* names[]{"get_asset", "set_asset", "getLayerCount", "setLayerCount", "getLayer", "setLayer",
                "get_Pause", "set_Pause", "get_EnabledOverrideUpdateTiming", "set_EnabledOverrideUpdateTiming",
                "get_BlendRate", "set_BlendRate"};
            for (unsigned i = 0; i < methods.size(); ++i) if (m == methods[i]) diagnostic.method = names[i];
        }
        int status;
        try {
            status = sdk->method->invoke(m, object, args.data(), n * sizeof(void*), result.bytes.data(), result.bytes.size());
        } catch (...) {
            if (!diagnostic.failed) { diagnostic.native_exception = true; diagnostic.failed = true; }
            throw;
        }
        const bool success = status == REFRAMEWORK_ERROR_NONE && result.bytes[128] == 0;
        if (!success && !diagnostic.failed) {
            diagnostic.sdk_error = status; diagnostic.exception = result.bytes[128] != 0; diagnostic.failed = true;
        }
        return success;
    }
    bool call(REFrameworkMethodHandle m, Object object, std::initializer_list<uintptr_t> values) const {
        Result result;
        return invoke(m, object, result, values);
    }
    template<class T> bool read(REFrameworkMethodHandle m, Object object, T& out,
                               std::initializer_list<uintptr_t> values = {}) const {
        Result result;
        if (!invoke(m, object, result, values)) return false;
        out = result.template get<T>();
        return true;
    }
    bool holder_resource(Object holder, Resource& out) const {
        if (!is(holder, holder_type)) return false;
        std::memcpy(&out, reinterpret_cast<const unsigned char*>(holder) + 0x10, sizeof(out));
        return true;
    }
    bool asset(Object object, Resource& out) {
        Object holder{};
        if (!read(get_asset, object, holder)) return false;
        if (!holder) { out = nullptr; return true; }
        if (!is(holder, holder_type)) return false;
        Pin<Object> temporary(refs);
        temporary.acquire(holder);
        return holder_resource(holder, out);
    }
    bool settings(Object layer, bool paused) {
        uint8_t pause{}, timing{};
        // Single 方法返回经 invoke 包装提升为 double；不能按原字段的 float 布局读取。
        double blend{};
        if (!read(get_pause, layer, pause) || !read(get_timing, layer, timing) ||
            !read(get_blend, layer, blend)) return false;
        diagnostic.settings_read = true;
        diagnostic.pause = pause;
        diagnostic.expected_pause = paused ? 1 : 0;
        diagnostic.timing = timing;
        diagnostic.blend = blend;
        return pause == diagnostic.expected_pause && timing == 0 && blend == 1.0;
    }
    struct Original { Object layer{}; Resource asset{}; };
    bool originals(const std::array<Original, 15>& original, unsigned count) {
        for (unsigned i = 0; i < count; ++i) {
            Object layer{}; Resource resource{};
            if (!read(get_layer, component, layer, {i}) || layer != original[i].layer) return false;
            if (layer && (!is(layer, layer_type) || !asset(layer, resource) || resource != original[i].asset)) return false;
        }
        return true;
    }
    bool rollback(const std::array<Original, 15>& original, unsigned count, Object ours) noexcept {
        try {
            int32_t current = -1;
            if (!owner() || !read(get_count, component, current) || !originals(original, count)) return false;
            if (current == static_cast<int32_t>(count)) return true;
            if (current != static_cast<int32_t>(count + 1)) return false;
            Object tail{};
            if (!read(get_layer, component, tail, {count}) || (tail && tail != ours)) return false;
            // Do not retry a failed mutating call: it may already have committed.
            call(set_count, component, {count});
            return read(get_count, component, current) && current == static_cast<int32_t>(count) && originals(original, count);
        } catch (...) { return false; }
    }
public:
    Operation(const REFrameworkSDKData* s, Memory& m, References& r, Diagnostic& d, uintptr_t root_, uintptr_t component_, bool f)
        : sdk(s), memory(m), refs(r), diagnostic(d), root(reinterpret_cast<Object>(root_)), component(reinterpret_cast<Object>(component_)),
          fingers(f), component_type(f ? "via.motion.JointConstraints" : "via.motion.IkLeg2"),
          resource_type(f ? "via.motion.JointConstraintsResource" : "via.motion.IkLeg2Resource"),
          holder_type(f ? "via.motion.JointConstraintsResourceHolder" : "via.motion.IkLeg2ResourceHolder"),
          resource_pin(r), holder(r), layer(r) {}

    // Allocation/resource loading is outside the scene critical section. No scene objects are touched.
    int prepare() {
        diagnostic.enter("metadata");
        if (!resolve()) return BadSignature;
        diagnostic.enter("resource.create");
        auto manager = sdk->functions->get_resource_manager();
        if (!manager) return ResourceFailed;
        auto resource = sdk->resource_manager->create_resource(manager, resource_type, fingers ? fingers_path : ik_path);
        if (!resource) return ResourceFailed;
        // create_resource returns its creation credit. create_holder owns a separate resource credit.
        resource_pin.adopt(resource);
        diagnostic.enter("holder.create");
        auto new_holder = sdk->resource->create_holder(resource, holder_type);
        if (!new_holder) return HolderFailed;
        holder.acquire(new_holder);
        Resource held_resource{};
        if (!holder_resource(new_holder, held_resource) || held_resource != resource) return HolderFailed;
        if (fingers) {
            diagnostic.enter("layer.create");
            auto new_layer = sdk->type_definition->create_instance(type(layer_type), REFRAMEWORK_CREATE_INSTANCE_FLAGS_NONE);
            if (!new_layer) return LayerFailed;
            layer.acquire(new_layer);
            if (!is(new_layer, layer_type)) return LayerFailed;
            diagnostic.enter("layer.configure");
            Resource empty{};
            if (!asset(new_layer, empty) || empty) return LayerFailed;
            // 方法的 Single 入参也使用 double 槽位，不能套用直接写 float 字段的布局。
            if (!call(set_pause, new_layer, {1}) || !call(set_timing, new_layer, {0}) ||
                !call(set_asset, new_layer, {reinterpret_cast<uintptr_t>(new_holder)}) ||
                !call(set_blend, new_layer, {0x3ff0000000000000ULL})) return InvokeFailed;
            Resource assigned{};
            if (!asset(new_layer, assigned) || assigned != resource || !settings(new_layer, true)) return ReadbackFailed;
        }
        return Applied;
    }

    int commit(unsigned expected_count) {
        diagnostic.enter("target.validate");
        if (!owner()) return BadOwner;
        Pin<Object> root_pin(refs), component_pin(refs);
        root_pin.acquire(root); component_pin.acquire(component);
        int32_t count = -1;
        if (fingers && (!read(get_count, component, count) || count != static_cast<int32_t>(expected_count))) return CountChanged;
        const auto resource = resource_pin.value;
        const auto new_holder = holder.value;
        const auto new_layer = layer.value;
        if (!fingers) {
            Resource current{};
            if (!asset(component, current)) return ReadbackFailed;
            if (current == resource) return Applied;
        }
        std::array<Original, 15> original{};
        for (unsigned i = 0; fingers && i < expected_count; ++i) {
            if (!read(get_layer, component, original[i].layer, {i})) return InvokeFailed;
            if (original[i].layer && (!is(original[i].layer, layer_type) || !asset(original[i].layer, original[i].asset)))
                return ReadbackFailed;
            if (original[i].asset == resource) return Applied;
        }
        if (!fingers) {
            if (!owner()) return BadOwner;
            diagnostic.enter("ik.assign");
            // IK is a single submission, including the error path. No speculative second setter.
            if (!call(set_asset, component, {reinterpret_cast<uintptr_t>(new_holder)})) return InvokeFailed;
            Resource current{};
            return asset(component, current) && current == resource ? Applied : ReadbackFailed;
        }
        if (!owner()) return BadOwner;
        if (!read(get_count, component, count) || count != static_cast<int32_t>(expected_count) ||
            !originals(original, expected_count)) return CountChanged;
        int status = InvokeFailed;
        diagnostic.enter("fingers.append");
        try {
            // From this point even a reported failure may have grown/attached the tail.
            bool grew = call(set_count, component, {expected_count + 1});
            Object tail{};
            if (grew && read(get_count, component, count) && count == static_cast<int32_t>(expected_count + 1) &&
                originals(original, expected_count) && read(get_layer, component, tail, {expected_count}) && !tail && owner()) {
                if (call(set_layer, component, {expected_count, reinterpret_cast<uintptr_t>(new_layer)}) &&
                    read(get_layer, component, tail, {expected_count}) && tail == new_layer &&
                    call(set_pause, new_layer, {0}) && settings(new_layer, false) &&
                    read(get_count, component, count) && count == static_cast<int32_t>(expected_count + 1) &&
                    originals(original, expected_count) && owner()) return Applied;
            }
        } catch (...) { status = Unexpected; }
        diagnostic.failed = true; // Preserve the original failure through guarded rollback.
        return rollback(original, expected_count, new_layer) ? status : RollbackFailed;
    }
};

// Prepared private objects never enter Lua. The scene lease encloses only validation/commit;
// its destruction precedes releasing the private holder/layer and resource creation credit.
template<class Memory, class Lock>
int execute(const REFrameworkSDKData* sdk, Memory& memory, uintptr_t root, uintptr_t component,
            unsigned expected_count, bool fingers, Lock acquire_lock, Diagnostic* output = nullptr) noexcept {
    if (!root || !component || root == component || (fingers ? expected_count < 1 || expected_count > 15 : expected_count != 0))
        return BadArguments;
    if (!available(sdk)) return MissingApi;
    References refs{sdk};
    Diagnostic local;
    Diagnostic& diagnostic = output ? *output : local;
    int result = Unexpected;
    try {
        Operation<Memory> operation(sdk, memory, refs, diagnostic, root, component, fingers);
        result = operation.prepare();
        if (result == Applied) {
            diagnostic.enter("scene.lock");
            auto guard = acquire_lock();
            result = guard.held ? operation.commit(expected_count) : Busy;
        }
    }
    catch (...) { diagnostic.native_exception = true; result = Unexpected; }
    return refs.cleanup_failed ? CleanupFailed : result;
}
} // namespace bsfn_resource
