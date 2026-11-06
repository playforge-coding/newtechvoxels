# Rendering

The renderer (`src/render`) draws chunks from faces the GPU built. The CPU only ever uploads.

## Buffers

| Buffer | Holds | Size |
| --- | --- | --- |
| voxels | every chunk's palette words followed by its packed data words, carved up by a range allocator | 24 MB |
| faces | every chunk's faces, 8 bytes each, carved up by a range allocator | 48 MB |
| records | one `Chunk_Record` per slot: offsets into the two buffers above, bit width, palette length, the six neighbor slots, the face range, the position | 4096 slots |
| indirect | one `Draw_Args` per slot, written by the CPU and then by the meshing shader | 4096 slots |
| dirty | the slots to mesh this frame | 256 |
| camera | view-projection, position, sun direction | 96 bytes |
| blocks | color and solidity per block id | 16 bytes per block |

The two range allocators are first fit over a sorted free list with coalescing (`alloc.odin`). A chunk that doesn't fit is skipped and counted, not crashed on.

## Meshing

When a chunk arrives or changes, `upload_chunk` writes its words, computes its occupancy bitmask (one bit per voxel, from the registry's solidity) and marks it and its six neighbors dirty. Each frame, `mesh_dirty` takes up to 256 dirty slots, counts each one's visible faces exactly with popcounts over the occupancy of the chunk and its neighbors (`mesh.count_faces`), allocates that many faces, writes the record and zeroed draw arguments (`vertex_count = 6`, `first_instance` = the face offset), and dispatches `shaders/mesh.wgsl` once for all of them: 128 workgroups of 256 threads per chunk, one thread per voxel. A thread whose voxel is solid claims an index with `atomicAdd` on the chunk's `instance_count` for each side with a non-solid neighbor and writes the face.

A face is `x:5 | y:5 | z:5 | normal:3 | ao:8` and `block id:16 | slot:16`. Ambient occlusion is the classic three-sample corner rule, 2 bits per corner. Samples one step outside the chunk come from the neighbor slot; samples two axes out read as air on both the CPU and the GPU, so the two agree exactly (the price is an AO seam at chunk edges, see the roadmap). `tests/render` compares the GPU's faces with `mesh.build_faces` for terrain and hand-made chunks.

## Drawing

`draw_chunks` writes the camera, extracts the frustum planes and issues one `DrawIndirect` per visible slot. `shaders/chunk.wgsl` reads the face for each instance and the record for its slot, places the quad's six vertices, and shades with a directional sun, sky light, the corner's AO and distance fog. Culling is off for now (quad winding isn't fixed yet), depth is 0..1 with a `Depth24Plus` buffer.

The device needs the `IndirectFirstInstance` feature so an indirect draw can start at the chunk's face offset. `MultiDrawIndirect` would collapse the per-chunk loop into one call and is on the roadmap.

## Headless

`renderer_init` with a nil surface renders into an offscreen texture of the given size. The GPU test and `--headless` benchmarks use it; on a machine without a GPU, Mesa's lavapipe provides a software Vulkan adapter.
