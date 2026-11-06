# Roadmap

Finished items stay where they are, checked off.

## The MVP

A single-player-capable, multiplayer-ready voxel world with the benchmark harness.

- [x] Toolchain, justfile, licenses, CI
- [x] Cubic chunks with palettes and packed indices, canonical codec
- [x] Block registry with the built-in blocks
- [x] Deterministic terrain generation
- [x] Occupancy, exact face counting, CPU reference mesher
- [x] wgpu device, GPU meshing into one face buffer, indirect draws
- [x] First-person player with collision, jumping and flying
- [x] Breaking and placing blocks
- [x] `sim` and `host` as libraries; singleplayer over the in-memory transport
- [x] Client prediction with reconciliation
- [x] Region files with Zstandard
- [x] Telemetry with percentiles and CSV output; the terrain, edits and static scenes
- [ ] The QUIC transport over noq (Rust C ABI shim in `sdk/noq-ffi`, Odin binding in `sdk/noq`)
- [ ] The dedicated server executable (`src/server`)
- [ ] The packet-loss scene (joining under 5% loss)
- [ ] Rendering other players
- [ ] First benchmark results against Beta 1.7.3

## After the MVP

- [ ] Face winding and back-face culling
- [ ] `MultiDrawIndirect` so one call draws every visible chunk
- [ ] Ambient occlusion across chunk edges (needs the 20 edge and corner neighbors or a border exchange)
- [ ] Space reclaim in region files
- [ ] Chunk generation and loading off the main thread
- [ ] A face-capacity guard in the vertex shader for chunks whose count and mesh disagree
- [ ] Textures and a block atlas
- [ ] Light propagation beyond the directional sun
- [ ] P2P hosting with iroh: discovery, hole punching, relays
- [ ] Voice chat (Opus) and webcam sharing (AV1, AV2 as an experiment) over MoQ
- [ ] Selective physics with Box3D: explosions, falling trees
- [ ] The modding runtime (WebAssembly leading) and the `sdk/` API
- [ ] unipute replacing the hand-written compute kernels
