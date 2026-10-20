# AGENTS.md

The goal of this project is for Ed to prove (or kill) a theory: that a Docker
build cache can be pushed and pulled *asynchronously* between CI nodes, and
that knowing the git commit graph makes cross-branch cache reuse work the way
people expect it to when they cut `v1.25.8` four months after anyone last
touched `flight/v1.25`.

It is a spike. Nothing here is production code, including the Vagrant cluster,
which exists to make measurements honest rather than to model the real fleet.

## Scope

- The question is *how does cache data move between nodes*, not how do we build
  an app. Anything that doesn't change a number in a test result is out of
  scope.
- Ed is working alongside you, probably in `build.sh`, `README.md` and
  `test/Dockerfile` at the root of the repo - those are his original spike
  files, ask before rewriting them. The harness (`Vagrantfile`, `env.sh`,
  `test.sh`, `test/`) is yours to keep working.
- Branches: `master` is the dev environment plus the file-based (BuildKit
  `type=local`) proof. `registry` is the registry-based spike, which is where
  the interesting comparison lives.

## Style

- Tight solutions.
- No bloat, no comments unless asked or the solution is confusing, no defensive
  code for cases that don't exist yet.
- Match the existing style of the file you're editing. `env.sh`, `test.sh` and
  `Vagrantfile` deliberately follow `~/Projects/Home/deployed`.
- Report measured numbers, not inferred ones, and keep them comparable: same
  fixture, same node sizes, same starting state.

## Environment

```
./env.sh up        # 3 x ubuntu 26.04 nodes (libvirt), then snapshots them
./env.sh restore   # every node back to empty caches, ~13s
./env.sh status
./test.sh restore file-cache
```

- Nodes: `node1` `node2` `node3`, ssh forwarded to `127.0.0.1:12231-12233`,
  private network `192.168.78.11-13`, and `vagrant` -> `vagrant` passwordless
  ssh between every pair over the private network (`.vagrant/cluster_key`).
  The subnet and port range differ from `deployed` on purpose so both clusters
  can be up at once.
- Each node has Ubuntu's own `docker.io` (29.1.x), `docker-buildx`, `skopeo`,
  `rsync` and `zstd`. There is no CI runner on the nodes: Docker only.
- libvirt snapshotting is `virsh save` for RAM plus an internal `qemu-img`
  snapshot for the disk, taken per node by `env.sh snapshot`. Without the disk
  half a restore would come back with the caches the last test filled it with.

## Verification

- `bash -n` anything you edit, then run it: cache behaviour is the whole
  subject of this repo, so a test that cannot be run is not a result.
- A test run is only meaningful after `./env.sh restore` (or `./test.sh restore
  <name>`). Never compare a "warm" build against a node that already built the
  same thing.
- `./test_all.sh` runs every `test/*.sh` with a restore before each.
- Don't claim success without testing, and don't quote a number you didn't
  watch come out of a run.

## Known measurements

These came out of runs on this cluster; re-verify before repeating them, and
add to the list rather than arguing with it.

- Replicating a `type=local` cache directory works: node2 built an image in 2s
  that took node1 47s cold, and produced the same binary.
- It replicates the whole directory every time. One changed line of repo code
  put 147 MB on the wire to move 1.4 MB of new blobs: 105x amplification, and
  147 MB of extra disk per commit per node.
- `--build-arg` values only change the cache key when the Dockerfile declares
  them. A per-node proxy URL is a cache-key footgun, so the Vagrantfile gives
  every node the same `apt-cache` name in `/etc/hosts` (it isn't reachable from
  these nodes today, so the tests use `APT_PROXY=`).
- BuildKit does not replay the output of a `CACHED` step. Compare what the
  images *do* (`test/lib.sh: image_digest`) rather than what the build log
  said.
- A `registry:2` sink stores a new commit for roughly the size of its new
  blobs, because blobs are content-addressed and a push skips what the
  registry already has. That is the property the directory layout is missing.

## Git discipline

- Avoid `git stash` on the working tree, Ed is probably working alongside you.
- If we need a clean tree to test something, ask first or work around it (copy
  files, use a scratch dir).
- Never `git add`, `commit`, `push`, or `stash drop` without explicit
  instruction.

## Communication

Concise. Say what changed and why, nothing else. No preamble, no summary of
work already shown.
