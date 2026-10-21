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

`docker.sh` and `reconcile.sh` - the async half, actually running (`test/registry-reconcile.sh`):

- node1 builds a commit cold in 45s, exports it to its own registry, and - given `--local` - pushes nothing to anyone
- node2 has a reconciler standing there that only asks "which refs does the cluster have that I don't"; it pulls the
  ref 1s later, and builds the same commit in 12s and the same binary digest
- the next commit costs 3.0 MB on the wire and 6.0 MB of disk on node2, against a 155 MB ref
- an idle cluster moves nothing: passes over a converged cluster report 0 refs brought over, and a build whose peers
  already hold the ref prints "nothing to send".  There is no event stream, so there is nothing to echo back.
- `flight/v1.25`, which has its own dependency layer, costs that layer and nothing else: 115 MB

The link, made slow and made to die (`test/registry-blocking.sh`).  `tc htb`/`netem` shapes node1's egress; the ref is
the same 161 MB one commit:

| link from the peer | fetch a whole ref | the build after it | on demand, start to finished image |
|---|---|---|---|
| unshaped (0.15ms RTT) | 1s, 162 MB | 11s | 12s |
| 1 gbit, 500us | 2s, 162 MB | 11s | 13s |
| 200 mbit, 15ms | 7s, 162 MB | 12s | 19s |
| 50 mbit, 15ms, wire cut at 4s | fails after 21 MB | 43s, 0 steps cached | 43s |

Two things this shape out.  **Fetching ahead of the build and prefetching by the reconciler are the same cost, not the
same risk**: at 200 mbit the prefetch wins by 1s of wall and, when it wins, it wins because the build never touches the
network - so the interesting difference is that a prefetch can be abandoned and a build-time fetch cannot.  **The next
commit is not the interesting one**: steady state moves 3.0 MB in 0s, because content addressing already knows which
layers the peer is missing; the cold-node case is the one the shaping is measuring.

A mid-fetch failure is the case no tag list protects against - the peer answered, was named, and then stopped serving
while the bytes were coming.  The build does not depend on that peer: `docker.sh` names each fetch that failed, imports
nothing, and builds anyway.  The cost is a cold build (43s, 0 cached steps against 11s warm), which is the same price as
never having had a cache, not a lost CI run.

## Driving it by hand

```
./env.sh restore && ./tools/deploy.sh        # nodes, registries, tools, ~/repo on each
ssh -F .vagrant/ssh_config ddn1              # ddn1-3 -> 192.168.78.11-13, per-machine key
cd ~/repo && git checkout flight/v1.25
~/ddcache/docker.sh --print .                # what it would build, and from which refs
~/ddcache/docker.sh .                        # build it, then hand the ref to the peers
~/ddcache/docker.sh --local .                # build it, let a reconciler notice instead
ssh -F .vagrant/ssh_config ddn2 '~/ddcache/reconcile.sh --once --verbose'
node2$ git fetch origin && git checkout -B flight/v1.25 origin/flight/v1.25
node2$ ~/ddcache/docker.sh .                 # warm, out of its own registry
```

`deploy.sh` is idempotent and cheap; run it after every restore, which rolls the node disks back and takes the tools,
registries and repos with them.  `~/repo` on node1 is the origin; the other nodes cloned it, so a commit made on node1
reaches node2 with an ordinary `git fetch`.  Add `Include /home/edward/Projects/Home/ddcache/.vagrant/ssh_config` to
your `~/.ssh/config` if you would rather type `ssh ddn1`.

What this changes about the concept above:

- the cache object is a registry ref, not a directory: `--cache-from`/`--cache-to type=registry,mode=max`, and
  ddcache never invents a file layout, a transfer format, or a dedup strategy
- a build never reads cache over the network.  `docker.sh` copies the ref it wants into its *own* registry first (one
  bounded, timed, byte-counted wait) and then points BuildKit at localhost.  BuildKit's own remote `--cache-from` was
  the alternative: it works, but a peer that is slow makes a build hang in a way the tool cannot time, name, or abandon,
  and a build that hangs on someone else's machine is a cache that has become a dependency
- refs are named `cache-<branch>-<commit>`, written only by the build of that commit, so concurrent builds never
  contend for one "latest" cache; a build asks for its branch's ref plus whatever the merge base suggests
- replication becomes a small policy problem - which refs on which node, and when - instead of a bandwidth problem
- `serve` does not need to advise anyone of anything, or hold a peer list: state converges when each node compares
  "what the cluster has" against "what I have" on a timer.  A lost notification costs one interval, which is the
  whole point of the async design; `join`/`leave` is a line in a file
- the sharp edge moves to storage: every branch ref stays in the registry forever unless something prunes it, and
  registry:2 here has GC disabled, so the spike never had to pay for keeping them
