#!/bin/bash
set -euo pipefail
cd -- "$(dirname -- "$0")/.."
source scripts/build-environment.sh

if [[ -d "$source/.git" ]] && [[ "$(git -C "$source" rev-parse HEAD)" == "$openjpeg_revision" ]]; then
    printf 'OpenJPEG %s is already available.\n' "$openjpeg_revision"
    exit 0
fi
[[ ! -e "$source" && ! -L "$source" ]] || {
    echo 'Existing OpenJPEG checkout has a different revision. Move it aside before bootstrapping.' >&2
    exit 1
}
temp="$(mktemp -d "$work/openjpeg-fetch.XXXXXX")"
trap 'rm -rf -- "$temp"' EXIT
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null GIT_TERMINAL_PROMPT=0
git -c init.templateDir= init --quiet "$temp"
git -C "$temp" -c core.hooksPath=/dev/null -c protocol.file.allow=never fetch --quiet --depth=1 --no-tags \
    "$openjpeg_url" "$openjpeg_revision"
[[ "$(git -C "$temp" rev-parse 'FETCH_HEAD^{commit}')" == "$openjpeg_revision" ]]
git -C "$temp" -c core.hooksPath=/dev/null checkout --quiet --detach "$openjpeg_revision"
mv "$temp" "$source"
printf 'Fetched and pinned OpenJPEG %s.\n' "$openjpeg_revision"
