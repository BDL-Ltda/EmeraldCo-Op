#!/bin/sh
set -eu

if [ "$#" -gt 1 ]; then
    printf '%s\n' 'Usage: build-rom.sh [jobs: 1-256]' >&2
    exit 2
fi

jobs=
if [ "$#" -eq 1 ]; then
    jobs=$1
    case "$jobs" in
        ''|*[!0-9]*)
            printf '%s\n' 'Jobs must be an integer between 1 and 256.' >&2
            exit 2
            ;;
    esac
    # Strip leading zeroes before arithmetic checks, including long inputs.
    while [ "${jobs#0}" != "$jobs" ]; do
        jobs=${jobs#0}
    done
    if [ -z "$jobs" ] || [ "${#jobs}" -gt 3 ] || [ "$jobs" -gt 256 ]; then
        printf '%s\n' 'Jobs must be an integer between 1 and 256.' >&2
        exit 2
    fi
fi

if ! command -v docker >/dev/null 2>&1; then
    printf '%s\n' 'Docker was not found. Install Docker and make sure docker is on PATH.' >&2
    exit 1
fi

script_directory=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
repository_root=$(CDPATH= cd -- "$script_directory/.." && pwd -P)

set -- compose --project-directory "$repository_root" \
    -f "$repository_root/docker-compose.yml" run --build --rm
if [ -n "$jobs" ]; then
    set -- "$@" --env "JOBS=$jobs"
fi

exec docker "$@" rom
