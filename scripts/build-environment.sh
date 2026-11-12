# Sourced by build.sh and bootstrap-openjpeg.sh after changing into the project.
project="$(pwd -P)"
case "$project/" in
    /Volumes/*)
        [[ "$(stat -f %d "$project")" != "$(stat -f %d /Volumes)" ]] || {
            echo 'The project volume is not mounted.' >&2
            exit 1
        }
        ;;
esac

work="$project/.build"
[[ ! -L "$work" ]] || { echo '.build must be a directory inside the project.' >&2; exit 1; }
mkdir -p "$work"

readonly openjpeg_url='https://github.com/uclouvain/openjpeg.git'
readonly openjpeg_revision='8314119b067c0fc77834731168daaebd379fdb12'
readonly source="$work/openjpeg"
