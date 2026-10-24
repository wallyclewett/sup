#!/bin/zsh
# Make Assets.xcassets (the app icon in all sizes) from make_icon.swift.
# Run again after you change the drawing. build.sh compiles it into the app.
set -e
here=${0:a:h}
work=$(mktemp -d)
swiftc "$here/make_icon.swift" -o "$work/make_icon"
"$work/make_icon" "$work/icon.png"
set_dir="$here/Assets.xcassets/AppIcon.appiconset"
rm -rf "$here/Assets.xcassets"
mkdir -p "$set_dir"
echo '{"info":{"version":1,"author":"xcode"}}' > "$here/Assets.xcassets/Contents.json"
entries=()
for px in 16 32 128 256 512; do
    for scale in 1 2; do
        suffix=""
        if [[ $scale == 2 ]]; then suffix="@2x"; fi
        name="icon_${px}x${px}${suffix}.png"
        sips -z $((px * scale)) $((px * scale)) "$work/icon.png" --out "$set_dir/$name" >/dev/null
        entries+=("{\"idiom\":\"mac\",\"size\":\"${px}x${px}\",\"scale\":\"${scale}x\",\"filename\":\"$name\"}")
    done
done
echo "{\"images\":[${(j:,:)entries}],\"info\":{\"version\":1,\"author\":\"xcode\"}}" > "$set_dir/Contents.json"
rm -rf "$work"
echo "Made $here/Assets.xcassets"
