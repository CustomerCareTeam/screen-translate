#!/bin/zsh
set -euo pipefail
cd -- "${0:A:h}"

source_app="$PWD/dist/Screen Translate.app"
installed_app="/Applications/Screen Translate.app"
executable="Contents/MacOS/ScreenTranslate"
bundle_id="local.screentranslate.app"

check_bundle() {
    [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$1/Contents/Info.plist")" == "$bundle_id" ]]
}

check_bundle "$source_app"
codesign --verify --strict "$source_app"
if [[ -e "$installed_app" || -L "$installed_app" ]]; then
    check_bundle "$installed_app"
fi

stage="$(mktemp -d /Applications/.ScreenTranslate-install.XXXXXXXX)"
installed_new=false
committed=false
finish() {
    local result=$?
    trap - EXIT
    if [[ "$committed" == false ]]; then
        if [[ "$installed_new" == true ]]; then
            mv "$installed_app" "$stage/failed.app" || return 1
        fi
        if [[ -d "$stage/previous.app" ]]; then
            mv "$stage/previous.app" "$installed_app" || return 1
        fi
    fi
    rm -rf -- "$stage"
    return "$result"
}
trap finish EXIT

ditto "$source_app" "$stage/new.app"
codesign --verify --strict "$stage/new.app"
for pid in ${(f)"$(pgrep -x ScreenTranslate || true)"}; do
    process="$(ps -p "$pid" -o comm= || true)"
    if [[ "$process" == "$installed_app/$executable" || "$process" == "$source_app/$executable" ]]; then
        kill -TERM "$pid"
    fi
done

if [[ -e "$installed_app" || -L "$installed_app" ]]; then
    mv "$installed_app" "$stage/previous.app"
fi
mv "$stage/new.app" "$installed_app"
installed_new=true
codesign --verify --strict "$installed_app"
cmp "$source_app/$executable" "$installed_app/$executable"

open -n "$installed_app" --args --request-screen-recording
for attempt in {1..30}; do
    for pid in ${(f)"$(pgrep -x ScreenTranslate || true)"}; do
        if [[ "$(ps -p "$pid" -o comm= || true)" == "$installed_app/$executable" ]]; then
            committed=true
            printf 'Running Screen Translate from %s (PID %s)\n' "$installed_app" "$pid"
            exit 0
        fi
    done
    sleep 0.2
done
printf 'Screen Translate did not start from /Applications.\n' >&2
exit 1
