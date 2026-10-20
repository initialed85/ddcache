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

## Tradeoffs / deliberate choices / otherwise expected and accepted sharp edges

- Nothing will be compressed, to keep CPU usage down on nodes that are probably important build machines
- This will not be efficient from a storage perspective
- This will not be efficient from a network perspective
- The lever we're pulling is all about making Docker builds as fast as we can
- Some cache misses are inevitable due to the asynchronous design
- Tie-breaking for same-build, same-commit will be one by timestamp

## Dev notes

The Nginx-based `apt` proxy stuff isn't a requirement, it's just me playing around and it also helps to keep iteration
times down given a lot of testing is all about clearing caches and building again to see what happens.

## What the cluster measured

Three libvirt nodes, a throwaway two-stage Go repo, and `--cache-to` as the only variable.  Every run starts from a
restored snapshot, so "cold" really means cold.  `./test_all.sh` reproduces all of it; the numbers below are one run.

`type=local` - a cache directory per commit, replicated node to node (`test/file-cache.sh`):

- one commit's export is the whole cache: 147 MB in 10 files
- a one-line change puts 1.4 MB of genuinely new content into it, and the export is still 147 MB
- moving that commit to another node puts 147 MB on the wire: **105x amplification**
- the third node costs another 147 MB, whether or not it needs any of it
- wall clock per replication is 0-15s depending on whether the export is still in the host's page cache, so the bytes,
  not the seconds, are the honest measure - and the bytes scale with the size of everything ever built

The directory is not content addressed: the export writes a fresh copy of every layer, so "replicate the cache" means
"copy all of it".  That is the whole cost of the file design, and no amount of clever transfer wins against it.

`type=registry` - one ref per branch+commit (`test/registry-cache.sh`, `test/registry-up.sh`):

- first commit: ref is 161 MB, replication moves 162 MB (one time)
- second commit, one line in `app.go`: registry grows 2.9 MB, replication moves 3.0 MB, node2 builds in 3s
- a node with no replicated anything builds in 2s by naming someone else's registry, pulling 119 MB - only the layers
  the build materialises, not the 161 MB the ref contains
- three refs over four distinct layers occupy 284 MB, not 3x161 MB: blobs are shared between refs

An old branch is where the naming earns its keep.  `flight/v1.25` was cut at the first commit and has its own
dependency layer; a fix lands on it after master has moved on, and node2 has never seen the branch:

- `--cache-from` the branch's own commit ref: 11s, 2 cached steps
- `--cache-from` master's newest ref, which is what a "latest" key gives you: 46s, 0 cached steps

Same node, same registry, same build; the only difference is which ref was named.  Content addressing takes care of
what to transfer, and the commit graph has to take care of what to name.

What this changes about the concept above:

- the cache object is a registry ref, not a directory: `--cache-from`/`--cache-to type=registry,mode=max`, and
  ddcache never invents a file layout, a transfer format, or a dedup strategy
- refs are named `cache-<branch>-<commit>`, written only by the build of that commit, so concurrent builds never
  contend for one "latest" cache; a build asks for its branch's ref plus whatever the merge base suggests
- replication becomes a small policy problem - which refs on which node, and when - instead of a bandwidth problem
- the sharp edge moves to storage: every branch ref stays in the registry forever unless something prunes it, and
  registry:2 here has GC disabled, so the spike never had to pay for keeping them
