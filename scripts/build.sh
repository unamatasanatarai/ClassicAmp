#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
project_dir="$(cd "${script_dir}/.." && pwd)"
cd "$project_dir"

source "${script_dir}/config.sh"

cache_dir="${XDG_CACHE_HOME:-$HOME/.cache}/${APP_NAME,,}"
mkdir -p "$cache_dir"

sdk_file="${cache_dir}/sdk_path.tmp"
xcrun --show-sdk-path >"$sdk_file" 2>/dev/null
if [[ ! -s "$sdk_file" ]]; then
    rm -f "$sdk_file"
    printf '%s\n' "Error: Failed to obtain SDK path from xcrun" >&2
    exit 1
fi
IFS= read -r sdk_path <"$sdk_file"
rm -f "$sdk_file"

if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    printf '%s\n' "Error: VERSION file must contain a version like 1.2.3 (found '${VERSION}')" >&2
    exit 1
fi

# Every build increments BUILD_NUMBER; the file is the single source of truth.
if [[ "$BUILD_NUMBER" =~ ^[0-9]+$ ]]; then
    build_number=$((10#$BUILD_NUMBER + 1))
else
    build_number=1
fi
printf '%s\n' "$build_number" >"$build_num_file"
export BUILD_NUMBER="$build_number"

build_dir="build"
app_name="${APP_NAME}"
bundle_id="${BUNDLE_ID}"
app_dir="${build_dir}/${app_name}.app"
contents_dir="${app_dir}/Contents"
macos_dir="${contents_dir}/MacOS"
resources_dir="${contents_dir}/Resources"

mkdir -p "$macos_dir" "$resources_dir"

if [[ -d "Resources" ]]; then
    cp -R Resources/. "${resources_dir}/"
fi

if [[ -f "VERSION" ]]; then
    cp "VERSION" "${resources_dir}/VERSION"
fi
printf '%s\n' "$build_number" >"${resources_dir}/BUILD_NUMBER"

sources=()
while IFS= read -r file; do
    sources+=("$file")
done < <(find Sources/App -type f -name "*.swift" | sort)

# Universal binary: one slice per architecture, merged with lipo.
# ARCHS="x86_64" (or "arm64") builds a single slice for quicker local iteration.
archs=(${ARCHS:-x86_64 arm64})
slices=() pids=()
printf '%s\n' "Compiling ${app_name} v${VERSION} (Build ${BUILD_NUMBER}) for ${archs[*]} (${#sources[@]} source files)..."
for arch in "${archs[@]}"; do
    slice="${build_dir}/${app_name}-${arch}"
    swiftc -sdk "$sdk_path" \
        -target "${arch}-apple-macos${MIN_MACOS_VERSION}" \
        -O \
        -whole-module-optimization \
        -Xlinker -dead_strip \
        "${sources[@]}" \
        -o "$slice" &
    slices+=("$slice") pids+=($!)
done
for pid in "${pids[@]}"; do
    wait "$pid" || { printf '%s\n' "Error: compilation failed" >&2; exit 1; }
done
lipo -create "${slices[@]}" -output "${macos_dir}/${app_name}"
rm -f "${slices[@]}"
printf '%s\n' "Architectures: $(lipo -archs "${macos_dir}/${app_name}")"

printf '%s\n' "Generating ${app_name} Info.plist..."
cat <<EOF >"${contents_dir}/Info.plist"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>${app_name}</string>
    <key>CFBundleIdentifier</key>
    <string>${bundle_id}</string>
    <key>CFBundleName</key>
    <string>${app_name}</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>${VERSION}</string>
    <key>CFBundleVersion</key>
    <string>${BUILD_NUMBER}</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon.icns</string>
    <key>CFBundleIconName</key>
    <string>AppIcon</string>
    <key>LSMinimumSystemVersion</key>
    <string>${MIN_MACOS_VERSION}</string>
    <key>LSUIElement</key>
    <${LS_UI_ELEMENT}/>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSHumanReadableCopyright</key>
    <string>${COPYRIGHT}</string>
    <!-- File types Finder may open with this app ("Open With", and "Change All…" to make it the default). -->
    <key>CFBundleDocumentTypes</key>
    <array>
        <dict>
            <key>CFBundleTypeName</key>
            <string>Audio File</string>
            <key>CFBundleTypeRole</key>
            <string>Viewer</string>
            <key>LSHandlerRank</key>
            <string>Default</string>
            <key>LSItemContentTypes</key>
            <array>
                <string>public.mp3</string>
                <string>public.mpeg-4-audio</string>
                <string>com.apple.m4a-audio</string>
                <string>com.apple.protected-mpeg-4-audio</string>
                <string>public.aac-audio</string>
                <string>org.xiph.flac</string>
                <string>com.microsoft.waveform-audio</string>
                <string>public.aiff-audio</string>
                <string>public.aifc-audio</string>
                <string>com.apple.coreaudio-format</string>
                <string>public.audio</string>
            </array>
        </dict>
        <dict>
            <key>CFBundleTypeName</key>
            <string>Playlist</string>
            <key>CFBundleTypeRole</key>
            <string>Viewer</string>
            <key>LSHandlerRank</key>
            <string>Alternate</string>
            <key>LSItemContentTypes</key>
            <array>
                <string>public.m3u-playlist</string>
                <string>public.pls-playlist</string>
                <string>${bundle_id}.cue</string>
            </array>
        </dict>
        <dict>
            <key>CFBundleTypeName</key>
            <string>Classic Skin</string>
            <key>CFBundleTypeRole</key>
            <string>Viewer</string>
            <key>LSHandlerRank</key>
            <string>Owner</string>
            <key>LSItemContentTypes</key>
            <array>
                <string>${bundle_id}.wsz</string>
            </array>
        </dict>
    </array>
    <!-- .cue and .wsz have no system type: declare them so Finder can associate them. -->
    <key>UTImportedTypeDeclarations</key>
    <array>
        <dict>
            <key>UTTypeIdentifier</key>
            <string>${bundle_id}.cue</string>
            <key>UTTypeDescription</key>
            <string>CUE Sheet</string>
            <key>UTTypeConformsTo</key>
            <array><string>public.plain-text</string></array>
            <key>UTTypeTagSpecification</key>
            <dict>
                <key>public.filename-extension</key>
                <array><string>cue</string></array>
            </dict>
        </dict>
        <dict>
            <key>UTTypeIdentifier</key>
            <string>${bundle_id}.wsz</string>
            <key>UTTypeDescription</key>
            <string>Classic Skin</string>
            <key>UTTypeConformsTo</key>
            <array><string>public.zip-archive</string></array>
            <key>UTTypeTagSpecification</key>
            <dict>
                <key>public.filename-extension</key>
                <array><string>wsz</string></array>
            </dict>
        </dict>
    </array>
</dict>
</plist>
EOF

# macOS remembers granted permissions (TCC) against the app's designated requirement.
# Ad-hoc signing defaults to a per-build cdhash requirement, which loses permissions on
# every rebuild, so pin the requirement to the bundle ID instead. No keychain is used.
designated_requirement="designated => identifier \"${bundle_id}\""

printf '%s\n' "Signing ${app_name} bundle (ad-hoc, ${designated_requirement})..."
codesign --force --deep --sign - --requirements "=${designated_requirement}" "$app_dir"

signed_requirement="$(codesign -d -r- "$app_dir" 2>&1 | grep '^designated => ' || true)"
if [[ "$signed_requirement" != "$designated_requirement" ]]; then
    printf '%s\n' "Error: Unexpected designated requirement '${signed_requirement}'; permissions would not persist." >&2
    exit 1
fi

printf '%s\n' "Refreshing macOS LaunchServices cache..."
touch "$app_dir"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f -R "$app_dir" >/dev/null 2>&1 || true
qlmanage -r cache >/dev/null 2>&1 || true

printf '%s\n' "✅ Build complete:"
printf '%s\n' "   - ${app_dir}"
