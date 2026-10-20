#!/bin/sh

set -e

if [ ! -f /var/cache/apt-cache/.apt-cache-disk ]; then
	echo "no .apt-cache-disk marker: the apt-cache disk isn't mounted on this node" >&2
	exit 1
fi

mkdir -p /var/cache/apt-cache/nginx

chown nginx /var/cache/apt-cache/nginx

exec nginx -g 'daemon off;'

