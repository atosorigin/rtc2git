#!/usr/bin/env bash
set -e

while [ $# -gt 0 ]; do

    case $1 in
        -s|--stream)
            STREAM=$2
            shift
            ;;
        -i|--include-roots)
            INCLUDE_ROOTS=yes
            ;;
        -r|--reconfigure)
            IGNORE_EXISTING_WORKSPACE=yes
            ;;
        -u|--unit) # install systemd unit
            SYSTEMD_INSTALL=yes
            ;;
        -t|--timer) # enable systemd timer
            SYSTEMD_START=yes
            ;;
        -m|--migrate-repo)
            MIGRATE_REP=$2
            shift
            ;;
        -h|--help)
            echo >&2 "Usage: $0 -m|--migrate-repo RTC_REPO -s|--stream RTC_STREAM [-i|--include-roots] [-r|--reconfigure] [-u|--unit] [-t|--timer] [-h|--help]"
            echo >&2 "migrate-repo: the RTC repository (can also be set using MIGRATE_REP environment)"
            echo >&2 "stream: the RTC stream"
            echo >&2 "include-roots: include component roots while loading"
            echo >&2 "reconfigure: regenerate existing stream configuration"
            echo >&2 "unit: install systemd unit and timer (but keep disabled)"
            echo >&2 "timer: enable timer"
            echo >&2 "help: show this"
            exit 0
            ;;
        *)
            echo >&2 "Unknown switch $1"'!'
            exit 1
            ;;
    esac

    shift

done

# use saved session per default
SAVED=yes

# ignore history by default
IGNORE_HISTORY_MODE=yes

# Required ENV:
# STREAM - stream to be migrated
# RTC_USERNAME, RTC_PASSWORD - RTC credentials
# Optional ENV:
# WS_PREFIX - for namespacing the workspaces, e.g. for testing
# MIGRATE_DEBUG - set to any value to debug this shell script (uses set -v -x)

# Unstable, do not use:
# SUBSYSTEM - the subsystem this stream belongs to, if unset, STREAM will be used.

[ -z "$MIGRATE_REP" ] && { echo >&2 "Missing RTC repository!"; exit 9; }
[ -z "$STREAM" ] && { echo >&2 "Missing stream!"; exit 2; }
[ -z "$RTC_USERNAME" ] || [ -z "$RTC_PASSWORD" ] && [ -z "$SAVED" ] && { echo >&2 "RTC username and/or password missing/empty!"; exit 3; }

[ -z "$RTC_USERNAME" ] && RTC_USERNAME=rtc2git
[ -z "$SUBSYSTEM" ] && SUBSYSTEM=$STREAM

[ "$WS_PREFIX" ] && WS_PREFIX="_${WS_PREFIX}"
# IMPORT_MODE does not require additional processing
[ "$MIGRATE_DEBUG" ] && set -x -v
[ "$INCLUDE_ROOTS" ] && USE_COMPONENT_ROOTS="IncludeComponentRoots = True"
[ "$IGNORE_HISTORY_MODE" ] && USE_EXISTSING_WORKSPACE="useExistingWorkspace = True"

MIGRATE_DIR="migrate/${STREAM}"
MIGRATE_WSP=${RTC_USERNAME}${WS_PREFIX}_migrate_${STREAM}

if [ "$SAVED" ]; then
    RTC_CONNECTION="--repository-uri ${MIGRATE_REP}"
    RTC2GIT_CREDS="-s"
else
    RTC_CONNECTION="--username ${RTC_USERNAME} --password ${RTC_PASSWORD} --repository-uri ${MIGRATE_REP}"
    RTC2GIT_CREDS="--user ${RTC_USERNAME} --password ${RTC_PASSWORD}"
fi

if [ "$IGNORE_HISTORY_MODE" ]; then

    echo >&2 "Checking for workspace existance..."

    if [ `lscm list workspace --name "${MIGRATE_WSP}" ${RTC_CONNECTION} | wc -l` -gt 0 ]; then
        if [ -z "$IGNORE_EXISTING_WORKSPACE" ]; then
            echo >&2 "A workspace for ${STREAM} in ${SUBSYSTEM} already exists! (${MIGRATE_WSP})"
            exit 8;
        else
            echo >&2 "A workspace $MIGRATE_WSP already exists, reconfiguring..."
        fi
    else
        lscm create workspace --stream "${STREAM}" "${MIGRATE_WSP}" ${RTC_CONNECTION}
    fi

fi

INI=config/${STREAM}.ini
UNIT=config/${STREAM}.service
TIMER=config/${STREAM}.timer
cat >$INI <<EOF
[General]
Repo = ${MIGRATE_REP}
GIT-Reponame = ${STREAM}.git
${USE_EXISTSING_WORKSPACE}

WorkspaceName= ${MIGRATE_WSP}
Directory = ${PWD}/${MIGRATE_DIR}

ScmCommand = lscm

[Migration]
StreamToMigrate = ${STREAM}

[Miscellaneous]
${USE_COMPONENT_ROOTS}
LogShellCommands = True
EOF

cat >$UNIT <<EOF
[Unit]
Description=rtc2git migration for ${STREAM} stream service

[Service]
Type=oneshot
User=rtc2git
WorkingDirectory=${PWD}
Environment=PYTHONUNBUFFERED=UNBUFFERED
ExecStart=/usr/bin/python3 migration.py -c config/${STREAM}.ini ${RTC2GIT_CREDS}
EOF

cat >$TIMER <<EOF
[Unit]
Description=Periodically run migration for ${STREAM}

[Timer]
# every 5 minutes
OnCalendar=*:0/5
# do not start all migrations at once
# 3,25 min delay
RandomizedDelaySec=225
EOF

if [ "$SYSTEMD_INSTALL" ]; then
    sudo systemctl link ${PWD}/${UNIT}
    sudo systemctl link ${PWD}/${TIMER}
fi

if [ "$SYSTEMD_START" ]; then
    sudo systemctl start ${STREAM}.timer
fi
