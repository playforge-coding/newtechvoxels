// Draws chunk faces. Each instance is one face from the face buffer (see
// mesh.wgsl for the layout); six vertices make its two triangles. Shading
// is a directional sun, ambient light, and the per-corner ambient
// occlusion the mesher computed.

// Mirrors `Camera_Uniform` in src/render/camera.odin.
struct Camera {
    view_proj: mat4x4<f32>,
    position: vec4<f32>,
    // xyz: direction toward the sun, w: unused.
    sun: vec4<f32>,
}

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

@group(0) @binding(0) var<uniform> camera: Camera;
@group(0) @binding(1) var<storage, read> faces: array<vec2<u32>>;
@group(0) @binding(2) var<storage, read> records: array<ChunkRecord>;
@group(0) @binding(3) var<storage, read> blocks: array<vec4<f32>>;

struct VertexOut {
    @builtin(position) position: vec4<f32>,
    @location(0) color: vec3<f32>,
    @location(1) normal: vec3<f32>,
    @location(2) ao: f32,
    @location(3) world_pos: vec3<f32>,
}

fn normal_dir(n: u32) -> vec3<f32> {
    switch n {
        case 0u: { return vec3<f32>(1.0, 0.0, 0.0); }
        case 1u: { return vec3<f32>(-1.0, 0.0, 0.0); }
        case 2u: { return vec3<f32>(0.0, 1.0, 0.0); }
        case 3u: { return vec3<f32>(0.0, -1.0, 0.0); }
        case 4u: { return vec3<f32>(0.0, 0.0, 1.0); }
        default: { return vec3<f32>(0.0, 0.0, -1.0); }
    }
}

fn tangent1(n: u32) -> vec3<f32> {
    if n < 2u {
        return vec3<f32>(0.0, 1.0, 0.0);
    }
    return vec3<f32>(1.0, 0.0, 0.0);
}

fn tangent2(n: u32) -> vec3<f32> {
    if n < 4u {
        return vec3<f32>(0.0, 0.0, 1.0);
    }
    return vec3<f32>(0.0, 1.0, 0.0);
}

// Two triangles over the four corners; corner c is at (c & 1, c >> 1)
// along the tangents, which is also the order of the AO bits.
fn corner_of_vertex(v: u32) -> u32 {
    switch v {
        case 0u: { return 0u; }
        case 1u: { return 1u; }
        case 2u: { return 2u; }
        case 3u: { return 2u; }
        case 4u: { return 1u; }
        default: { return 3u; }
    }
}

@vertex
fn vs_main(
    @builtin(vertex_index) vertex_index: u32,
    @builtin(instance_index) instance_index: u32,
) -> VertexOut {
    let face = faces[instance_index];
    let x = f32(face.x & 31u);
    let y = f32((face.x >> 5u) & 31u);
    let z = f32((face.x >> 10u) & 31u);
    let n = (face.x >> 15u) & 7u;
    let ao_bits = (face.x >> 18u) & 0xFFu;
    let block = face.y & 0xFFFFu;
    let slot = face.y >> 16u;
    let r = records[slot];

    let corner = corner_of_vertex(vertex_index);
    let normal = normal_dir(n);
    // Faces on the positive side sit one unit along the normal.
    let offset = max(normal, vec3<f32>(0.0));
    let t1 = tangent1(n) * f32(corner & 1u);
    let t2 = tangent2(n) * f32(corner >> 1u);
    let origin = vec3<f32>(f32(r.px), f32(r.py), f32(r.pz)) * 32.0;
    let world = origin + vec3<f32>(x, y, z) + offset + t1 + t2;

    var out: VertexOut;
    out.position = camera.view_proj * vec4<f32>(world, 1.0);
    out.color = blocks[block].xyz;
    out.normal = normal;
    out.ao = f32((ao_bits >> (corner * 2u)) & 3u) / 3.0;
    out.world_pos = world;
    return out;
}

@fragment
fn fs_main(in: VertexOut) -> @location(0) vec4<f32> {
    let sun = normalize(camera.sun.xyz);
    let diffuse = max(dot(in.normal, sun), 0.0);
    // Faces away from the sun still get some sky light from above.
    let sky = 0.5 + 0.5 * in.normal.y;
    let light = 0.25 + 0.2 * sky + 0.6 * diffuse;
    let ao = 0.45 + 0.55 * in.ao;
    var color = in.color * light * ao;
    // Distance fog toward the sky color.
    let dist = length(in.world_pos - camera.position.xyz);
    let fog = clamp((dist - 120.0) / 160.0, 0.0, 1.0);
    color = mix(color, vec3<f32>(0.62, 0.76, 0.92), fog);
    return vec4<f32>(color, 1.0);
}
