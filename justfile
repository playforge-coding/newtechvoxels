# Every command for the project. Recipes only run things; logic belongs in
# the code and in tools/. Compiler flags shared by all builds live in the
# variables below, not repeated per recipe.

set shell := ["bash", "-euo", "pipefail", "-c"]
set positional-arguments

# Flags for every Odin build and test: vet, one spelling per identifier,
# warnings fail the build, the sdk collection, and mold where it exists.
linker := if os() == "linux" { "-linker:mold" } else { "" }
check_flags := "-vet -strict-style -warnings-as-errors -collection:sdk=sdk"
odin_flags := check_flags + " " + linker
out := "out"

default:
    @just --list

# Downloads the wgpu-native library the vendor:wgpu bindings link into Odin's
# vendor directory, which is where they look for it. Run once per machine.
setup:
    @mkdir -p {{out}}
    odin run tools/setup -out:{{out}}/setup {{odin_flags}}

# Build the client in release mode into out/. The dedicated server
# executable arrives with the QUIC transport.
build:
    @mkdir -p {{out}}
    odin build src/client -out:{{out}}/newtechvoxels -o:speed {{odin_flags}}

# Run the client with any arguments (`just run --bench terrain`).
run *args: build
    {{out}}/newtechvoxels "$@"

# Type-check every package without linking, then validate the shaders.
check:
    odin check src/client {{check_flags}}
    odin check tools/setup {{check_flags}}
    for d in tests/*/; do odin check "$d" -no-entry-point {{check_flags}}; done
    for f in shaders/*.wgsl; do naga "$f"; done

# Run every test package under tests/.
test:
    @mkdir -p {{out}}/tests
    for d in tests/*/; do odin test "$d" -out:{{out}}/tests/$(basename "$d") {{odin_flags}}; done

# Run one test package, with optional -define flags (`just test-one world`).
test-one pkg *args:
    @mkdir -p {{out}}/tests
    odin test tests/{{pkg}} -out:{{out}}/tests/{{pkg}} {{odin_flags}} "${@:2}"

# Run the benchmark scenes headless and write their CSVs into out/bench/.
bench *args: build
    @mkdir -p {{out}}/bench
    {{out}}/newtechvoxels --bench all --bench-out {{out}}/bench "$@"

# Format every Odin file in place.
fmt:
    for d in src sdk tests tools; do if [ -d "$d" ]; then odinfmt -w "$d"; fi; done

# Fail if any Odin file isn't formatted (CI runs this).
fmt-check: fmt
    git diff --exit-code -- src sdk tests tools

# Build and preview the docs site.
docs:
    uvx zensical build --strict

docs-serve:
    uvx zensical serve

# Sync the tree to a build machine and run a recipe there, like
# `just remote test`. The host is an ssh alias from your own ~/.ssh/config.
host := env_var_or_default("NTV_BUILD_HOST", "ntv-build")
remote_dir := "Developer/newtechvoxels"

remote +args:
    rsync -az --delete --exclude .git --filter=':- .gitignore' ./ {{quote(host + ":" + remote_dir + "/")}}
    ssh -- {{quote(host)}} "export PATH=\"\$HOME/.cargo/bin:\$HOME/.local/bin:\$PATH\" && cd {{remote_dir}} && mise trust -q && mise exec -- just $(printf '%q ' "$@")"
    rsync -az -m --include='/out/' --include='/out/bench/***' --exclude='*' {{quote(host + ":" + remote_dir + "/")}} ./
