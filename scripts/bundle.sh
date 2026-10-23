#!/bin/sh
# usage: scripts/bundle.sh [debug|release]   (UNIVERSAL=1 for arm64 + x86_64, SWIFT_FLAGS for extra build flags)
set -eu

config=${1:-release}
case "$config" in
    debug | release) ;;
    *) echo "usage: scripts/bundle.sh [debug|release]" >&2; exit 2 ;;
esac

root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"

version=$(tr -d '[:space:]' < VERSION)
app="$root/build/Earshot.app"

set -- -c "$config"
if [ "${UNIVERSAL:-0}" = 1 ]; then
    set -- "$@" --arch arm64 --arch x86_64
fi
set -- "$@" ${SWIFT_FLAGS:-}

scripts/sbuild build "$@"
bin=$(scripts/sbuild build "$@" --show-bin-path | tail -n 1)

for exe in Earshot earshot-hook; do
    [ -x "$bin/$exe" ] || { echo "missing $bin/$exe" >&2; exit 1; }
done

rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin/Earshot" "$bin/earshot-hook" "$app/Contents/MacOS/"
cp Resources/Info.plist "$app/Contents/Info.plist"
cp Resources/AppIcon.icns "$app/Contents/Resources/"
printf 'APPL????' > "$app/Contents/PkgInfo"

plutil -replace CFBundleShortVersionString -string "$version" "$app/Contents/Info.plist"
plutil -replace CFBundleVersion -string "$version" "$app/Contents/Info.plist"

for res in "$bin"/Earshot_*.bundle; do
    [ -e "$res" ] || continue
    case "$res" in *Tests.bundle) continue ;; esac
    cp -R "$res" "$app/Contents/Resources/"
done

if [ "${UNIVERSAL:-0}" = 1 ]; then
    for exe in Earshot earshot-hook; do
        archs=$(lipo -archs "$app/Contents/MacOS/$exe")
        case "$archs" in
            *arm64*x86_64* | *x86_64*arm64*) ;;
            *) echo "$exe is not universal: $archs" >&2; exit 1 ;;
        esac
    done
fi

xattr -cr "$app"
identity=-
if [ -z "${CI:-}" ] && security find-identity -p codesigning 2>/dev/null | grep -q '"Earshot Local"'; then
    identity="Earshot Local"
fi
codesign --force --sign "$identity" --timestamp=none --identifier io.github.knqzx.earshot.hook "$app/Contents/MacOS/earshot-hook"
codesign --force --sign "$identity" --timestamp=none "$app"
codesign --verify --strict --verbose=1 "$app"

echo "built $app ($version, $config, signed with $identity)"
