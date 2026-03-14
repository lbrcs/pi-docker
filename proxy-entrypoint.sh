#!/bin/sh
# Remove stale PID file left over from a previous container run.
# The proxy container filesystem persists between sessions, so Squid would
# otherwise refuse to start thinking another instance is already running.
rm -f /run/squid.pid

# Squid drops to the 'proxy' user after startup. /dev/stdout and /dev/stderr
# are owned by root by default, so we fix permissions while still running as root.
chmod o+w /dev/stdout /dev/stderr
exec squid -f /etc/squid/squid.conf -N
