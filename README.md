# mongo-mirror

A standby mirror for a MongoDB database: it produces a compressed archive and restores it
onto a spare mongod.

It knows nothing about the application it serves — you give it two connection strings and
a database name, and it does its job.

## Why it exists

**The main benefit is not failover, it is the backup.** A database on a managed service
has no copy under your control: if someone deletes data by mistake, your only safety net
is the provider's own backup — which shared tiers do not have. The archive produced here
fills that gap, **provided it ends up in an offsite backup**: sitting on a local volume it
is a copy on the very disk you are trying to protect.

The standby mongod is the runner-up prize: if the source becomes unreachable you repoint
the application's connection string and carry on, with data at most one cycle old.

## How it works

1. `mongodump` of the whole database into a compressed archive
2. `mongorestore` into a **staging** database on the destination
3. document counts compared collection by collection, source against staging
4. only if they match does staging replace the standby database

Step 4 is the point: **an incomplete dump never replaces a sound copy**. On a mismatch the
standby keeps the previous cycle's data and the job exits with a distinct error.

## Usage

```bash
docker build -t mongo-mirror .
docker run --rm \
  -e MONGO_SOURCE_URI='mongodb+srv://user:password@cluster.example.net/mydb' \
  -e MONGO_TARGET_URI='mongodb://root:password@standby:27017/?authSource=admin' \
  -e MONGO_DB_NAME=mydb \
  -v mirror-data:/backup \
  mongo-mirror bash /usr/local/bin/dr-mirror-mongo.sh
```

### Variables

| Variable | Default | Notes |
|---|---|---|
| `MONGO_SOURCE_URI` | — | required |
| `MONGO_TARGET_URI` | — | if absent, only the archive is produced |
| `MONGO_DB_NAME` | — | required |
| `MONGO_MIRROR_WORKDIR` | `/backup` | mount a persistent volume here |
| `MONGO_KEEP_ARCHIVES` | `7` | how many archives to keep |

### Exit codes

Deliberately distinct, so an alert can say **where** to look instead of merely saying that
something failed:

| Code | Meaning |
|---|---|
| `0` | success |
| `1` | configuration error |
| `3` | source unreachable or invalid credentials |
| `4` | archive produced but counts differ — **the standby was not touched** |
| `5` | problem on the destination |

### Archive integrity

Every compressed archive is verified with `gzip -t` before the run is declared successful.
A truncated archive is the realistic failure here — the network drops, the disk fills, the
container restarts mid-dump — and a size check alone does not catch it: a half-written file
is not an empty file.

Archives are also published atomically. The dump is written to a `.partial` file in the
archive directory, verified there when compression provides a checksum, and only then
renamed to its final name. Consequently, a final `.gz` or `.archive` name always denotes a
completed dump (and a `.gz` has also passed verification); an interrupted run leaves a
self-describing `.partial` file that backup tools and archive rotation ignore. Stale partial
files are removed at the start of the next run.

This matters most with `--no-restore`. When the run also restores and compares counts, a
damaged archive is caught by the restore itself. Without that step the integrity check is
the only thing standing between a corrupt archive and the day you need it.

**Known gap**: uncompressed archives (`--no-compress`) are *not* verified. The BSON archive
format carries no checksum that can be validated without a running mongod, so there is
nothing cheap to check. If you turn compression off, rely on periodic restore tests.

### Knowing when it stops working

Every run — successful or not — writes `last-run.json` into the working directory:

```json
{ "timestamp": "...", "status": "ok", "exit_code": 0, "collections": 10,
  "documents": 154843, "archive_bytes": 32943217, "duration_seconds": 66 }
```

An external monitor should check **two things**: that the timestamp is fresh, and that
`status` is `ok`. The first matters more than the second — a job that stops running writes
nothing at all, and silence is how backups really fail.

## Running it on Coolify

Create a resource of type **Dockerfile**, with Build Context `/` and Dockerfile Location
`/Dockerfile`.

The image does not start mongod: it is the inert shell in which a **Scheduled Task** runs
`bash /usr/local/bin/dr-mirror-mongo.sh`. It stays alive because Coolify executes
scheduled tasks inside an already-running container — if this one exited immediately,
there would be nothing to step into.

The standby MongoDB is best created as another Coolify resource, not publicly exposed:
the two reach each other over the internal network by service name.

**Ordering matters**: this job must run *before* whatever backup collects the archive
volume. The other way round, every night you ship yesterday's archive offsite — a mistake
with no symptoms until the day you need it.

## Compression and deduplication

Archives are gzip-compressed by default. `--no-compress` (or `MONGO_ARCHIVE_COMPRESS=0`)
writes them raw, and whether that is a good idea depends entirely on what collects them.

A deduplicating backup tool cannot deduplicate compressed data: every compressed archive is
a fresh stream of unique bytes, so each night costs its full size in the backup repository.
An uncompressed archive, on the other hand, is mostly identical to yesterday's, so
content-defined chunking stores only what actually changed.

The catch is that the raw archive is several times larger, both on the local volume and —
if the backup repository cannot compress — in the repository itself. So:

- **repository with compression** (restic format v2, borg): uncompressed archives win
  clearly. You get deduplication *and* compression.
- **repository without compression** (restic format v1): it is roughly a wash on remote
  storage, and the uncompressed archives cost noticeably more local disk. Keep gzip.

Either way the difference tends to be small in absolute terms. Measure before optimising:
a deduplicating tool packs data into blobs of a few MB, so per-operation costs on object
storage stay negligible in both configurations.

## Constraints and limits

- **The destination cannot be an older major than the source.** The script checks and
  stops before touching anything. A mongod from a distribution package is almost always
  too old.
- `mongodump` against a live cluster is consistent per collection but **not across
  collections**, and managed providers usually do not expose the oplog to work around it.
  Fine for ordinary application data; if you need point-in-time consistency, use the
  provider's native backups.
- In a real failover the copy is up to one cycle old, and writes made against the standby
  will need reconciling if the source comes back.

## Notes

The script uses the native mongo tools when it finds them on `PATH` and falls back to
`docker run` only when they are missing, so the same copy works both inside the container
and from a workstation.

## License

MIT — see [LICENSE](LICENSE).
