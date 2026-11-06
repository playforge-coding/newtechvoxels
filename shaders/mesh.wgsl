// GPU meshing. One thread per voxel of each dirty chunk: if the voxel is
// solid, every side with a non-solid neighbor becomes a face, written into
// the chunk's range of the face buffer at an index claimed with an atomic
// on the chunk's indirect draw arguments. The CPU never reads anything
// back: it sized the range from an exact popcount, so the capacity check
// is only a guard.
//
// This mirrors src/mesh/mesh.odin exactly; the test in tests/render
// compares the two. Face layout (`Face` in mesh.odin):
//   a = x:5 | y:5 | z:5 | normal:3 | ao:8
//   b = block id:16 | chunk slot:16 (the slot is the GPU's addition)

// Mirrors `Chunk_Record` in src/render/chunks.odin.
struct ChunkRecord {
    data_offset: u32,
    palette_offset: u32,
    bits: u32,
    palette_len: u32,
    neighbors: array<u32, 6>,
    face_offset: u32,
    face_capacity: u32,
    px: i32,
    py: i32,
    pz: i32,
    pad: u32,
}

// Mirrors `Draw_Args` in src/render/chunks.odin and wgpu's indirect
// draw layout.
struct DrawArgs {
    vertex_count: u32,
    instance_count: atomic<u32>,
    first_vertex: u32,
    first_instance: u32,
}

const CHUNK_SIZE: i32 = 32;
const NO_SLOT: u32 = 0xFFFFFFFFu;

@group(0) @binding(0) var<storage, read> voxels: array<u32>;
@group(0) @binding(1) var<storage, read> records: array<ChunkRecord>;
// xyz color, w = 1 when solid.
@group(0) @binding(2) var<storage, read> blocks: array<vec4<f32>>;
@group(0) @binding(3) var<storage, read_write> faces: array<vec2<u32>>;
@group(0) @binding(4) var<storage, read_write> indirect: array<DrawArgs>;
// The slots to mesh this dispatch.
@group(0) @binding(5) var<storage, read> dirty: array<u32>;

fn voxel_index(x: i32, y: i32, z: i32) -> u32 {
    return u32((y * CHUNK_SIZE + z) * CHUNK_SIZE + x);
}

// The block id at a voxel inside the given slot.
fn block_at(slot: u32, x: i32, y: i32, z: i32) -> u32 {
    let r = records[slot];
    var palette_index = 0u;
    if r.bits != 0u {
        let bit = voxel_index(x, y, z) * r.bits;
        let word = voxels[r.data_offset + (bit >> 5u)];
        let mask = (1u << r.bits) - 1u;
        palette_index = (word >> (bit & 31u)) & mask;
    }
    return voxels[r.palette_offset + palette_index];
}

fn is_solid_block(id: u32) -> bool {
    return blocks[id].w > 0.5;
}

// Whether the voxel at (x, y, z), at most one step outside the chunk along
// one axis, is solid. Two axes out reads as air, like the CPU mesher.
fn solid_at(slot: u32, x: i32, y: i32, z: i32) -> bool {
    let out_x = x < 0 || x >= CHUNK_SIZE;
    let out_y = y < 0 || y >= CHUNK_SIZE;
    let out_z = z < 0 || z >= CHUNK_SIZE;
    var s = slot;
    var xx = x;
    var yy = y;
    var zz = z;
    let outs = u32(out_x) + u32(out_y) + u32(out_z);
    if outs > 1u {
        return false;
    }
    if out_x {
        s = records[slot].neighbors[select(0u, 1u, x < 0)];
        xx = x & 31;
    } else if out_y {
        s = records[slot].neighbors[select(2u, 3u, y < 0)];
        yy = y & 31;
    } else if out_z {
        s = records[slot].neighbors[select(4u, 5u, z < 0)];
        zz = z & 31;
    }
    if s == NO_SLOT {
        return false;
    }
    return is_solid_block(block_at(s, xx, yy, zz));
}

// Normal directions and tangents, in the order of mesh.odin's Normal.
fn normal_dir(n: u32) -> vec3<i32> {
    switch n {
        case 0u: { return vec3<i32>(1, 0, 0); }
        case 1u: { return vec3<i32>(-1, 0, 0); }
        case 2u: { return vec3<i32>(0, 1, 0); }
        case 3u: { return vec3<i32>(0, -1, 0); }
        case 4u: { return vec3<i32>(0, 0, 1); }
        default: { return vec3<i32>(0, 0, -1); }
    }
}

fn tangent1(n: u32) -> vec3<i32> {
    if n < 2u {
        return vec3<i32>(0, 1, 0);
    }
    return vec3<i32>(1, 0, 0);
}

fn tangent2(n: u32) -> vec3<i32> {
    if n < 4u {
        return vec3<i32>(0, 0, 1);
    }
    return vec3<i32>(0, 1, 0);
}

fn face_ao(slot: u32, p: vec3<i32>, n: u32) -> u32 {
    let base = p + normal_dir(n);
    let t1 = tangent1(n);
    let t2 = tangent2(n);
    var ao = 0u;
    for (var corner = 0u; corner < 4u; corner++) {
        let s1 = select(-1, 1, (corner & 1u) != 0u);
        let s2 = select(-1, 1, (corner >> 1u) != 0u);
        let pa = base + t1 * s1;
        let pb = base + t2 * s2;
        let pc = base + t1 * s1 + t2 * s2;
        let a = solid_at(slot, pa.x, pa.y, pa.z);
        let b = solid_at(slot, pb.x, pb.y, pb.z);
        let c = solid_at(slot, pc.x, pc.y, pc.z);
        var v = 0u;
        if !(a && b) {
            v = 3u - (u32(a) + u32(b) + u32(c));
        }
        ao |= v << (corner * 2u);
    }
    return ao;
}

@compute @workgroup_size(256, 1, 1)
fn mesh_chunk(
    @builtin(workgroup_id) group_id: vec3<u32>,
    @builtin(local_invocation_id) local_id: vec3<u32>,
) {
    let slot = dirty[group_id.y];
    let i = i32(group_id.x * 256u + local_id.x);
    let x = i & 31;
    let z = (i >> 5) & 31;
    let y = (i >> 10) & 31;
    let id = block_at(slot, x, y, z);
    if !is_solid_block(id) {
        return;
    }
    let r = records[slot];
    let p = vec3<i32>(x, y, z);
    for (var n = 0u; n < 6u; n++) {
        let q = p + normal_dir(n);
        if solid_at(slot, q.x, q.y, q.z) {
            continue;
        }
        let index = atomicAdd(&indirect[slot].instance_count, 1u);
        if index >= r.face_capacity {
            continue;
        }
        let ao = face_ao(slot, p, n);
        let a = u32(x) | (u32(y) << 5u) | (u32(z) << 10u) | (n << 15u) | (ao << 18u);
        let b = id | (slot << 16u);
        faces[r.face_offset + index] = vec2<u32>(a, b);
    }
}
