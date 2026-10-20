#!/bin/bash

set -e

mkdir -p cache

if ! test -e cache/index.json; then
	docker build \
		--build-arg HTTP_PROXY="http://172.17.0.1:3142" \
		--build-arg http_proxy="http://172.17.0.1:3142" \
		--cache-to "type=local,dest=${PWD}/cache,mode=max,tag=latest,compression=uncompressed" \
		-t initialed85/ttyd:latest \
		-f ./test/Dockerfile \
		.
else
	docker build \
		--build-arg HTTP_PROXY="http://172.17.0.1:3142" \
		--build-arg http_proxy="http://172.17.0.1:3142" \
		--cache-from "type=local,src=${PWD}/cache,mode=max,tag=latest,compression=uncompressed" \
		--cache-to "type=local,dest=${PWD}/cache,mode=max,tag=latest,compression=uncompressed" \
		-t initialed85/ttyd:latest \
		-f ./test/Dockerfile \
		.
fi
