# Live resource-maintenance drive: cross-worktree artifact dedup keeps writable files independent (R47 isolation invariant)

## setup: identical 2KB JSON in two worktrees, then run the real deduplicator (apply mode)
```console
{"files_scanned":2,"duplicate_instances":1,"bytes_reclaimed":0,"pairs":[{"status":"copied"}]}
inodes before: wtA=19852659 wtB=19852662
```

## invariant: dedup must NOT alias the two writable files (no hardlink), then writes must stay independent
```console
inodes after:  wtA=19852659 wtB=19852666  nlink: wtA=1 wtB=1
PASS: distinct inodes (independent storage)
PASS: nlink=1 on both
after writing wtA: wtA md5=5017da95670ff1fe95eef9163993d55d  -  wtB md5=285e44c6e916d3ec78e54ee00c15de6d  -
PASS: write to wtA did NOT propagate to wtB (isolation held)
```
