# Getting started

## Toolchain

Everything comes from [mise](https://mise.jdx.dev): Odin (a monthly release), ols (for `odinfmt`), just and naga-cli. From the repository root:

```sh
mise install
just setup
```

`just setup` downloads the wgpu-native library that Odin's `vendor:wgpu` binding links, into Odin's own vendor directory, which is where the binding looks for it. Run it again after changing the Odin version.

Odin links through `clang`, and on Linux the builds use `mold`. System libraries:

| Platform | Packages |
| --- | --- |
| Debian and Ubuntu | `clang mold libsdl3-dev liblz4-dev libzstd-dev`. Where there is no `libsdl3-dev` yet, build SDL 3.5 from source with CMake and Ninja (`-DSDL_TEST_LIBRARY=OFF`). |
| macOS | `brew install sdl3 lz4 zstd` and the Xcode command line tools for clang. |
| Windows | SDL3, lz4 and zstd through vcpkg; the bindings link `SDL3.lib`, `lz4` and `zstd.lib`. Not yet tried in CI. |

## Building and running

```sh
just build          # out/newtechvoxels, optimized
just run            # build and run
just run --seed 7 --view 6
```

Controls: mouse to look (click to capture, Esc to release), W A S D to move, Space to jump, F to toggle flying (Space and Shift go up and down), left click breaks, right click places, 1 to 9 pick the block.

The world is saved under `saves/default` (`--save <dir>` picks another) as region files when the game exits or evicts far chunks.

## Tests and checks

```sh
just test           # every package under tests/
just test-one sim   # one package
just check          # type-check everything and validate the shaders
just fmt            # odinfmt in place
```

The GPU test needs an adapter. Without one it logs that it was skipped and passes; with Mesa's lavapipe (`mesa-vulkan-drivers`) it runs on a headless machine.

## Benchmarks

```sh
just bench                       # every scene, headless, CSVs in out/bench/
just run --bench terrain         # one scene in a window
just run --bench edits --headless --bench-seconds 30
```

See [Benchmarks](benchmarks.md) for what the scenes do and how to report a result.

## A build machine

`just remote <recipe>` syncs the tree to a machine named by `NTV_BUILD_HOST` (an alias from your own `~/.ssh/config`) and runs the recipe there with that machine's mise, then copies `out/bench` back.
