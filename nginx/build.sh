#!/bin/bash

set -e

docker build -t initialed85/ddcache-nginx:latest -f ./Dockerfile .
