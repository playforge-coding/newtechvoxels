# New Tech Voxels

An experimental 3D voxel game aiming to harness the strengths of modern software, and a research project asking whether that stack is worth it, measured against early Minecraft.

Odin, SDL3, WebGPU (wgpu-native), QUIC, LZ4 and Zstandard. Chunks are meshed on the GPU from the same packed bytes that go over the network and to disk; the game logic is a library that singleplayer, dedicated servers and P2P hosts all run.

## Building

```sh
mise install     # Odin, ols, just, naga-cli
just setup       # wgpu-native into Odin's vendor directory
just build       # out/newtechvoxels
just test
```

You also need clang, SDL3, lz4 and zstd; see [Getting started](docs/getting-started.md).

## Documentation

The docs in `docs/` cover the [architecture](docs/architecture.md), [networking](docs/networking.md), [rendering](docs/rendering.md), [benchmarks](docs/benchmarks.md) and the [roadmap](docs/roadmap.md). `uvx zensical serve` previews them as a site.

## License

AGPL-3.0-or-later for the game. Everything under `sdk/` (the modding API and reusable bindings) is BSD-3-Clause.
