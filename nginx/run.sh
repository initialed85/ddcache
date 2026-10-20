#!/bin/bash

set -e

if ! test -d apt-cache; then
	mkdir -p apt-cache
	touch apt-cache/.apt-cache-disk
fi

docker run --rm -it -p 3142:3142 -v ${PWD}/apt-cache:/var/cache/apt-cache initialed85/ddcache-nginx:latest

