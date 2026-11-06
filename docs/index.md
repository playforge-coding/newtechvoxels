# New Tech Voxels

New Tech Voxels is an experimental 3D voxel game aiming to harness the strengths of modern software. It is also a research project with one question: is a modern, data-oriented stack actually worth it? The baseline is early Minecraft (Alpha through Beta 1.7.3), measured on the same machine with matched settings.

The stack: [Odin](https://odin-lang.org) for everything on the CPU, [SDL3](https://libsdl.org) for the window and input, WebGPU through [wgpu-native](https://github.com/gfx-rs/wgpu-native) for rendering and compute, QUIC for networking, LZ4 on the wire and Zstandard on disk.

What exists today:

- Cubic 32×32×32 chunks stored as a palette plus packed indices. The same bytes go to the GPU, over the network and to disk.
- Deterministic terrain from integer-hash noise: a seed gives the same world on every platform.
- Meshing on the GPU. The CPU uploads raw chunks and the exact face count (a popcount over occupancy bitmasks); a compute shader writes the faces and the draw arguments; nothing is ever read back.
- Authoritative game logic as a library (`sim`), run by a host over any transport. Singleplayer is a host in the same process over an in-memory transport; the client predicts with the same code and reconciles against acknowledged inputs.
- Region files with Zstandard, a telemetry recorder with percentile frame times, and three benchmark scenes that run headless.

What's next is on the [roadmap](roadmap.md). The game is free software: AGPL-3.0-or-later for the game, BSD-3-Clause for the SDK under `sdk/`.
