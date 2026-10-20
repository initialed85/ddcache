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
./env.sh restore   # every node back to empty caches, ~8s
./env.sh status
./test.sh restore file-cache
```

- Nodes: `node1` `node2` `node3`, reached by their static private addresses
  `192.168.78.11-13` with the per-machine key in `.vagrant/machines/<node>/`.
  Ports 12231-12233 are forwarded too, but nothing uses them: see Traps.
  `vagrant` -> `vagrant` passwordless ssh between every pair over the private
  network (`.vagrant/cluster_key`). The subnet and port range differ from
  `deployed` on purpose so both clusters can be up at once.
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

## Traps

- Host -> node ssh uses the static `192.168.78.1x` address, never
  `vagrant ssh-config`. Once libvirt's DHCP lease database goes empty (it does,
  after a few `virsh save`/`restore` cycles, and guests that keep their address
  do not always renew it) vagrant reports a running, reachable guest as
  `inaccessible` and refuses to produce ssh config at all.
- `vagrant reload`/`up` dies with `LoadError: cannot load such file -- erb`
  unless the `ruby-erb` pacman package is installed: Arch builds Vagrant
  against system ruby 3.4, where erb is a bundled gem, and the `vagrant`
  package does not depend on it.
- `lv.cpu_mode = "host-passthrough"` in the Vagrantfile is not a preference.
  The default (`host-model`) writes `<cpu mode='custom'>` with both a `<model>`
  and a `<vendor>`; a later redefine regenerates it without the model and
  libvirt rejects the XML ("CPU vendor specified without CPU model"), which
  leaves the domain running but makes every subsequent `reload`/`up` fail.
- `registry:2` GC is disabled by default and `docker system prune -a -f` wipes
  `/var/lib/docker`, so the registry's data dir lives outside it
  (`/var/lib/ddcache-registry`). Keep both in mind before trusting a
  "registry is small" number.
- Pushing/pulling over plain http needs `insecure-registries` in
  `/etc/docker/daemon.json` on *every* node that talks to the registry;
  `test/registry-lib.sh: node_allow_insecure` restarts dockerd only when the
  config actually changed, because a restart drops the builder.
- `skopeo copy` takes `--src-tls-verify=false`, not `--src-tlsverify`.
- `test/lib.sh` and `test/registry-lib.sh` are sourced, not run: `test.sh` and
  `test_all.sh` skip anything named `*lib.sh`.

## Known measurements

These came out of runs on this cluster; re-verify before repeating them, and
add to the list rather than arguing with it.

- Replicating a `type=local` cache directory works: node2 built an image in 2s
  that took node1 47s cold, and produced the same binary.
- It replicates the whole directory every time. One changed line of repo code
  put 147 MB on the wire to move 1.4 MB of new blobs: **105x amplification**,
  and 147 MB of extra disk per commit per node. Wall clock for that copy is
  0-15s depending on whether the export is still in the node's page cache, so
  quote the bytes; they are the part that scales.
- A `registry:2` sink stores a new commit for roughly the size of its new
  blobs: the same one-line commit grew the registry by 2.9 MB and cost 3.0 MB
  on the wire to bring another node up to date, against 147 MB for the
  directory. That is the property the file layout is missing.
- Replication is per-ref and content-addressed, so a node that already holds
  most of the blobs pays only for what is new: m0 cost 162 MB to node2, m1 cost
  3.0 MB. Replication is about *which* refs a node has, not how big the cache
  is.
- A node that builds straight out of another node's registry pulls only the
  layers the build materialises: 119 MB of a 161 MB ref for the first build,
  1.4 MB for the commit after. Its own registry stays at 0 bytes.
- Refs share blobs. Three refs over four distinct layers occupy 284 MB in the
  registry, not 3x161 MB.
- Naming is worth as much as transport. A fix on `flight/v1.25`, built on a
  node that had never seen the branch: `--cache-from` the branch's own commit
  ref gave 11s and 2 cached steps; `--cache-from` master's newest ref - what a
  "latest" key gets you - gave 46s and 0 cached steps, because the branch's
  dependency layer (it installs a package master's does not) is not in
  master's cache and never will be.
- `--build-arg` values only change the cache key when the Dockerfile declares
  them. A per-node proxy URL is a cache-key footgun, so the Vagrantfile gives
  every node the same `apt-cache` name in `/etc/hosts` (it isn't reachable from
  these nodes today, so the tests use `APT_PROXY=`).
- BuildKit does not replay the output of a `CACHED` step. Compare what the
  images *do* (`test/lib.sh: image_digest`) rather than what the build log
  said.
- The first `type=registry` export of a fixture costs about the same wall clock
  as a `type=local` one (46s vs 50s cold, 9s vs 10s warm): BuildKit pushes
  layers as it builds them instead of writing them out at the end, and the
  transport is local.

## Git discipline

- Avoid `git stash` on the working tree, Ed is probably working alongside you.
- If we need a clean tree to test something, ask first or work around it (copy
  files, use a scratch dir).
- Never `git add`, `commit`, `push`, or `stash drop` without explicit
  instruction.

## Communication

Concise. Say what changed and why, nothing else. No preamble, no summary of
work already shown.
