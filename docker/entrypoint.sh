#!/bin/bash

## Copyright (C) 2025 - 2025 ENCRYPTED SUPPORT LLC <adrelanos@whonix.org>
## See the file COPYING for copying conditions.

## TODO: document

set -x
set -o errexit
set -o nounset
set -o errtrace
set -o pipefail

container=docker
export container

if [ $# -eq 0 ]; then
  printf '%s\n' 'ERROR: No command specified. You probably want to run "journalctl -f", or maybe "bash"?' >&2
  exit 1
fi

if [ ! -t 0 ]; then
  printf '%s\n' 'ERROR: TTY needs to be enabled ("docker run -t ...").' >&2
  exit 1
fi

env | tee -- /etc/docker-entrypoint-env >/dev/null

## Debugging.
cat -- /etc/docker-entrypoint-env

true "INFO: Create file: /etc/systemd/system/docker-entrypoint.target"
## TODO: Consider making /etc/systemd/system/docker-entrypoint.target a standalone file.
cat > /etc/systemd/system/docker-entrypoint.target <<EOF
[Unit]
Description=the target for docker-entrypoint.service
Requires=docker-entrypoint.service systemd-logind.service systemd-user-sessions.service
EOF

quoted_args="$(printf " %q" "${@}")"
printf '%s\n' "${quoted_args}" | tee -- /etc/docker-entrypoint-cmd >/dev/null
chmod +x /etc/docker-entrypoint-cmd

true "INFO: Create file: /etc/systemd/system/docker-entrypoint.service"
## TODO: Consider making docker-entrypoint.service a standalone file.
cat > /etc/systemd/system/docker-entrypoint.service <<EOF
[Unit]
Description=docker-entrypoint.service

[Service]
ExecStartPre=/bin/bash -e -x -c "cat -- /etc/docker-entrypoint-cmd"
ExecStart=/bin/bash -e -x -c /etc/docker-entrypoint-cmd
## TODO: Consider making ExecStopPost a standalone script.
# EXIT_STATUS is either an exit code integer or a signal name string, see systemd.exec(5)
ExecStopPost=/bin/bash -ec "if echo \${EXIT_STATUS} | grep [A-Z] > /dev/null; then echo >&2 \"got signal \${EXIT_STATUS}\"; systemctl exit \$(( 128 + \$( kill -l \${EXIT_STATUS} ) )); else systemctl exit \${EXIT_STATUS}; fi"
StandardInput=tty-force
StandardOutput=inherit
StandardError=inherit
## TODO: Avoid WorkingDirectory.
WorkingDirectory=$(pwd)
EnvironmentFile=/etc/docker-entrypoint-env

[Install]
WantedBy=multi-user.target
EOF

systemctl mask systemd-firstboot.service systemd-udevd.service systemd-modules-load.service
systemctl unmask systemd-logind
systemctl enable docker-entrypoint.service

systemd=
if [ -x /lib/systemd/systemd ]; then
  systemd=/lib/systemd/systemd
elif [ -x /usr/lib/systemd/systemd ]; then
  systemd=/usr/lib/systemd/systemd
elif [ -x /sbin/init ]; then
  systemd=/sbin/init
else
  printf '%s\n' 'ERROR: systemd is not installed' >&2
  exit 1
fi

declare -a systemd_args=(
  --show-status=false
  --unit=docker-entrypoint.target
)

printf '%s\n' "$0: starting $systemd ${systemd_args[*]}"

exec "$systemd" "${systemd_args[@]}"
