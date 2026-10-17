#!/usr/bin/env sh
# Build Zed, then reclaim disk by removing the compiled artifacts.
#
# Usage:
#   ./build-and-clean.sh                  build (debug), then remove target/debug
#   ./build-and-clean.sh --release        build (release), then remove target/release
#   ./build-and-clean.sh --all            also remove the other profile's artifacts
#   ./build-and-clean.sh --keep-binary    keep the built binary (installed to ~/.local/opt/zed-plus/, run as 'zed-plus')
#   ./build-and-clean.sh clean            remove build artifacts without building
#   ./build-and-clean.sh clean --all      remove the entire target/ directory
#
# Run from the repo root.

set -eu

profile=debug
do_build=1
keep_binary=0
clean_all=0

for arg in "$@"; do
    case "$arg" in
        --release) profile=release ;;
        --keep-binary) keep_binary=1 ;;
        --all) clean_all=1 ;;
        clean) do_build=0 ;;
        -h | --help)
            sed -n '2,12p' "$0"
            exit 0
            ;;
        *)
            echo "unknown argument: $arg (run with --help for usage)" >&2
            exit 1
            ;;
    esac
done

if [ ! -f Cargo.toml ]; then
    echo "!! run this from the zed repo root (Cargo.toml not found)" >&2
    exit 1
fi

if [ "$do_build" -eq 1 ]; then
    echo "==> building ($profile)..."
    if [ "$profile" = release ]; then
        cargo build --release
    else
        cargo build
    fi
fi

if [ "$keep_binary" -eq 1 ]; then
    if [ -f "target/$profile/zed" ]; then
        install_dir="$HOME/.local/opt/zed-plus"
        mkdir -p "$install_dir" "$HOME/.local/bin"
        cp "target/$profile/zed" "$install_dir/zed-plus"
        ln -sf "$install_dir/zed-plus" "$HOME/.local/bin/zed-plus"
        echo "==> saved binary to $install_dir/zed-plus (run 'zed-plus')"
    else
        echo "!! target/$profile/zed not found, nothing saved" >&2
    fi
fi

if [ "$clean_all" -eq 1 ]; then
    if [ -d target ]; then
        size=$(du -sh target 2>/dev/null | cut -f1)
        echo "==> removing target/ ($size)..."
        rm -rf target
    fi
else
    if [ -d "target/$profile" ]; then
        size=$(du -sh "target/$profile" 2>/dev/null | cut -f1)
        echo "==> removing target/$profile ($size)..."
        rm -rf "target/$profile"
    fi
fi

echo "==> done"
