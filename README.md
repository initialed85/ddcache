# ddcache

`ddcache` tries to be a distributed Docker cache with a focus on async push / pull of cache data and a degree of
Git commit graph awareness with regards to finding the most relevant piece of cache data for a build.

## Goal

Maximal Docker build cache reuse across multiple nodes in multi-node CI system without relying on potentially slow and
synchronous network Docker build cache options like `type=registry`.

## Rough concept

- A Docker build is executed with the a `--cache-to` flag to write to a `type=local` cache
- After the Docker build (asynchronously with your CI job) the cache from that build is replicated to all other nodes
  with the context about where in the Git commit graph the cache applies to (probably commit hash and context like
  upstream branch a.k.a. "stream")
- The next Docker build (potentially on a different node) is executed with the a `--cache-from` flag to read from
  a `type=local` cache (containing the cache from the earlier build), as well as a `--cache-to` flag to write to a
  `type=local` cache

And the cycle repeats; in all cases the idea being a given Docker build is provided with the most relevant cache for
it's place in the Git commit graph, where most relevant is probably the most recent build in it's same branch or in the
upstream branch.

## Ergonomics

I think a dual purpose server / wrapper executable makes sense; so usage would be something like:

- `ddcache serve`
  - Listen on port 7878 by default
  - Expose all locally originated caches for download
  - Peer with other `ddcache` nodes
  - Advise peers when new locally originated caches become available
  - Download remotely discovered caches from peers as they become available
  - Prune stored locally originated and remotely discovered caches (keeping last n per stream)
- `ddcache join 192.168.1.111:7878`
  - Establish peering with `192.168.1.111:7878` (and implicitly with all peers `192.168.1.111:7878` knows about)
- `ddcache leave 192.168.1.111:7878`
  - Break peering with `192.168.1.111:7878` (and implicitly with all peers `192.168.1.111:7878` knows about)
- `ddcache docker build -t initialed85/ttyd:latest -f ./test/Dockerfile .`
  - (if present) Symlink the most relevant cache to a determined `--cache-from` path
    - e.g. `ln -s /tmp/ddcache/initialed85/ttyd/latest/${stream}/${most_recent_commit} ${PWD}/ddcache-from`
  - Symlink to a determined `--cache-to` path
    - e.g. `ln -s ${PWD}/ddcache-to /tmp/ddcache/initialed85/ttyd/latest/${stream}/${this_commit}`
  - Execute the described Docker build with the `--cache-from` and `--cache-to` flags as necessary
  - Hand off to `ddcache serve` for the slow task of coordination replicating
