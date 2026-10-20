# Spike build target for the cache tests.
#
# Two layers that behave differently across commits, which is the whole shape
# of the real problem:
#
#   * the dependency layer is expensive and stable - it should hit on every
#     node, on every branch, forever
#   * the compile layer depends on the contents of the repo, so it misses on
#     every new commit and is where cache transfer actually earns its keep
#
FROM ubuntu:26.04

# Passed by test/lib.sh.  Declared as an ARG, so it is part of the cache key -
# which is fine only because every node is given the same value (see the
# apt-cache /etc/hosts entry in the Vagrantfile).  Handing each node its own
# bridge IP here is how a "portable" cache stops being portable.
ARG APT_PROXY=

RUN set -eux; \
	if [ -n "$APT_PROXY" ]; then printf 'Acquire::http::Proxy "%s";\n' "$APT_PROXY" >/etc/apt/apt.conf.d/99proxy; fi; \
	apt-get update; \
	apt-get install -y --no-install-recommends build-essential ca-certificates; \
	rm -rf /var/lib/apt/lists/*

WORKDIR /src

# The repo contents: this is the bit that changes per commit.
COPY . .

RUN set -eux; \
	make -j"$(nproc)"; \
	./ddcheck 20000; \
	cp ddcheck /usr/local/bin/ddcheck
