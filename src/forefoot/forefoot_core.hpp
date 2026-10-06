#pragma once
#include <array>
#include <cmath>
#include <cstdint>
#include <cstring>

namespace forefoot {
using Address = uintptr_t;
enum Status { Applied = 0, Already = 1, Busy = 2, BadArguments = -1,
    UnsupportedHost = -2, BadOwner = -3, BadSkeleton = -4, BadChain = -5,
    BadMapping = -6, BadPose = -7, BadJoint = -8, MissingContext = -9 };
constexpr std::array<uint32_t, 6> hashes = {
    0x4d0e10c5, 0x6ded958a, 0x87f13496, 0x20bd0d5c, 0x17b78c57, 0x31754433};
constexpr std::array<unsigned, 4> targets = {1, 2, 4, 5};
struct Request { Address root_object, root, body_object, body, mesh; };
// 原生四元数 setter 使用对齐的 SIMD 读取，三个输入块均保留 16 字节对齐。
struct alignas(16) Pose { float position[4]{}, rotation[4]{}, scale[4]{}; };
struct Patch { Address joint, map; Pose bind; };
struct Plan { std::array<Patch, 4> patches{}; bool already = false; };

template<class T> T value(Address p, size_t offset = 0) {
    T v{};
    std::memcpy(&v, reinterpret_cast<const void*>(p + offset), sizeof(v));
    return v;
}
inline bool overlap(Address a, size_t an, Address b, size_t bn) {
    return a < b + bn && b < a + an;
}
inline bool valid_pose(const Pose& pose) {
    float norm = 0;
    for (unsigned i = 0; i < 3; ++i)
        if (!std::isfinite(pose.position[i]) || std::abs(pose.position[i]) > 10000) return false;
    for (float q : pose.rotation) { if (!std::isfinite(q)) return false; norm += q*q; }
    for (unsigned i = 0; i < 3; ++i)
        if (!std::isfinite(pose.scale[i]) || pose.scale[i] < 0.0001f || pose.scale[i] > 100) return false;
    return std::abs(norm - 1) < 0.001f;
}
inline bool same_pose(const Pose& a, const Pose& b) {
    for (unsigned i = 0; i < 3; ++i)
        if (std::abs(a.position[i] - b.position[i]) > 0.00001f ||
            std::abs(a.scale[i] - b.scale[i]) > 0.00001f) return false;
    for (unsigned i = 0; i < 4; ++i)
        if (std::abs(a.rotation[i] - b.rotation[i]) > 0.00001f) return false;
    return true;
}

// 先校验整组四项。所有校验失败均不写入；不保留任何跨调用的游戏地址。
template<class Memory>
Status prepare(Memory& memory, const Request& r, Plan& plan) {
    plan = {};
    if (!r.root || r.root == r.body || r.root_object == r.body_object ||
        !memory.range(r.root, 0x100, false) || !memory.range(r.body, 0x100, false) ||
        !memory.range(r.root_object, 0x20, false) || !memory.range(r.body_object, 0x20, false) ||
        !memory.range(r.mesh, 0x2a0, false)) return BadOwner;
    if (value<Address>(r.root, 0x10) != r.root_object ||
        value<Address>(r.root_object, 0x18) != r.root ||
        value<Address>(r.body, 0x10) != r.body_object ||
        value<Address>(r.body_object, 0x18) != r.body ||
        value<Address>(r.body, 0x60) != r.root ||
        value<Address>(r.mesh, 0x10) != r.body_object ||
        value<uint8_t>(r.body, 0xfa) != 1 ||
        (value<uint8_t>(r.mesh, 0x298) & 0xc0)) return BadOwner;
    const Address rs = value<Address>(r.root, 0xc8), bs = value<Address>(r.body, 0xc8);
    if (rs == bs || !memory.range(rs, 0x70, false) || !memory.range(bs, 0x70, false) ||
        value<Address>(rs, 0x10) != r.root || value<Address>(bs, 0x10) != r.body) return BadSkeleton;
    const uint32_t rn = value<uint32_t>(rs, 0x20), bn = value<uint32_t>(bs, 0x20);
    if (rn < 6 || bn < 6 || rn > 2048 || bn > 2048) return BadSkeleton;
    const Address rb = value<Address>(rs, 0x58), bb = value<Address>(bs, 0x58);
    const Address map = value<Address>(bs, 0x48), root_map = value<Address>(rs, 0x48);
    if (value<uint64_t>(bs, 0x50) != bn || !memory.range(map, bn*2, true) ||
        !memory.range(rb, rn*64, false) || !memory.range(bb, bn*64, false) ||
        (root_map && (!memory.range(root_map, rn*2, false) || overlap(map, bn*2, root_map, rn*2))) ||
        overlap(map, bn*2, rb, rn*64) || overlap(map, bn*2, bb, bn*64)) return BadSkeleton;
    std::array<int, 6> ri{}, bi{};
    ri.fill(-1); bi.fill(-1);
    for (unsigned which = 0; which < 2; ++which) {
        const Address bind = which ? bb : rb;
        const unsigned count = which ? bn : rn;
        auto& ids = which ? bi : ri;
        for (unsigned n = 0; n < count; ++n) {
            const auto hash = value<uint32_t>(bind, n*64+8);
            for (unsigned k = 0; k < hashes.size(); ++k) if (hash == hashes[k]) {
                if (ids[k] >= 0) return BadChain;
                ids[k] = static_cast<int>(n);
            }
        }
        for (int id : ids) if (id < 0) return BadChain;
        for (unsigned side : {0u, 3u})
            if (value<int16_t>(bind, ids[side+1]*64+12) != ids[side] ||
                value<int16_t>(bind, ids[side+2]*64+12) != ids[side+1]) return BadChain;
    }
    for (unsigned foot : {0u, 3u})
        if (value<int16_t>(map, bi[foot]*2) != ri[foot]) return BadMapping;
    const Address list = value<Address>(bs, 0x68);
    if (!memory.range(list, 0x20, false) || value<uint32_t>(list, 0x1c) != bn ||
        !memory.range(list+0x20, bn*8, false)) return BadJoint;
    std::array<Address, 3> own{}, parent{};
    const std::array<unsigned, 3> fields{0x18, 0x28, 0x38};
    for (unsigned k = 0; k < 3; ++k) {
        own[k] = value<Address>(bs, fields[k]); parent[k] = value<Address>(rs, fields[k]);
        if (!memory.range(own[k], bn*16, true) || !memory.range(parent[k], rn*16, false)) return BadPose;
        if (overlap(map, bn*2, parent[k], rn*16) ||
            (root_map && overlap(own[k], bn*16, root_map, rn*2))) return BadPose;
    }
    for (unsigned a = 0; a < 3; ++a) {
        for (unsigned b = 0; b < 3; ++b)
            if (overlap(own[a], bn*16, parent[b], rn*16) ||
                (a != b && overlap(own[a], bn*16, own[b], bn*16))) return BadPose;
        if (overlap(own[a], bn*16, map, bn*2) || overlap(own[a], bn*16, bb, bn*64) ||
            overlap(own[a], bn*16, rb, rn*64)) return BadPose;
    }
    unsigned detached = 0;
    bool locals_equal = true;
    for (unsigned p = 0; p < targets.size(); ++p) {
        const auto k = targets[p];
        const int mapped = value<int16_t>(map, bi[k]*2);
        if (mapped == -1) ++detached;
        else if (mapped != ri[k]) return BadMapping;
        auto& patch = plan.patches[p];
        patch.map = map + bi[k]*2;
        patch.joint = value<Address>(list, 0x20 + bi[k]*8);
        if (!memory.range(patch.joint, 0x20, false) || value<Address>(patch.joint, 0x10) != bs ||
            value<int32_t>(patch.joint, 0x18) != bi[k]) return BadJoint;
        std::memcpy(patch.bind.position, reinterpret_cast<void*>(bb+bi[k]*64+0x20), 12);
        std::memcpy(patch.bind.rotation, reinterpret_cast<void*>(bb+bi[k]*64+0x10), 16);
        std::memcpy(patch.bind.scale, reinterpret_cast<void*>(bb+bi[k]*64+0x2c), 12);
        if (!valid_pose(patch.bind)) return BadPose;
        Pose current{};
        std::memcpy(current.position, reinterpret_cast<void*>(own[0]+bi[k]*16), 12);
        std::memcpy(current.rotation, reinterpret_cast<void*>(own[1]+bi[k]*16), 16);
        std::memcpy(current.scale, reinterpret_cast<void*>(own[2]+bi[k]*16), 12);
        if (!valid_pose(current)) return BadPose;
        locals_equal = locals_equal && same_pose(current, patch.bind);
    }
    // 不接管别人已经解除的部分绑定，也不逐帧修复外部写入者。
    if (detached && (detached != 4 || !locals_equal)) return BadMapping;
    plan.already = detached == 4;
    return plan.already ? Already : Applied;
}

// 调用者持原生 Scene 锁。回调复用原生 Local setter 和 dirty 传播，绝不调用 World setter。
template<class Setters>
Status commit(const Plan& plan, Setters& setters) {
    if (plan.already) return Already;
    for (const auto& patch : plan.patches) {
        setters.position(patch.joint, patch.bind.position);
        setters.rotation(patch.joint, patch.bind.rotation);
        setters.scale(patch.joint, patch.bind.scale);
    }
    for (const auto& patch : plan.patches) {
        const int16_t detached = -1;
        std::memcpy(reinterpret_cast<void*>(patch.map), &detached, sizeof(detached));
    }
    return Applied;
}
} // namespace forefoot
