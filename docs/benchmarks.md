# Benchmarks

Measurement is a feature here, not an afterthought. `--bench <scene>` runs a scripted scene for a fixed time (`--bench-seconds`, default 20) and writes `out/bench/<scene>.csv` with one row per frame: time, frame and tick milliseconds, ticks run, chunks meshed, drawn and uploaded, faces drawn, chunks loaded on the host, chunks and bytes received and sent by the client. The log line at the end gives the frame time summary: average, p50, p99, 1% low, 0.1% low and max (as frame times, so higher is worse).

## Scenes

| Scene | What it does | What it measures |
| --- | --- | --- |
| `terrain` | flies forward over new terrain at fly speed, looking slightly down | chunk generation, streaming, upload and GPU meshing under constant load: the "chunk loading stutter" case |
| `edits` | stands still and breaks and places blocks every few ticks while turning | re-meshing of changed chunks and their neighbors |
| `static` | looks around without moving | the renderer alone: culling and draws |

`--headless` renders offscreen at `--size` without a window, for machines without a display. Frame times there have no vsync, so they are raw GPU and CPU time.

## Reporting a result

A result is only valid with its setup written down here: hardware, OS, driver, the build (commit and flags), the scene and its options. For a baseline comparison, the exact Minecraft version, its settings and JVM flags as well. Match view distance and world height, and say where a difference can't be matched. A bad result is still a result; record it.

## Results

None yet. The first comparison will be the `terrain` scene against Beta 1.7.3 at a matched view distance on the same machine.
