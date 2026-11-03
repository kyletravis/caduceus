# Backing up and restoring a Caduceus instance

`bin/caduceus-backup.sh` snapshots one instance (one checkout, one Compose project) into a single archive that can be restored later. Use it before upgrading Hermes, rebuilding images, editing `vendor/`, or making any other change you might want to undo.

## Quick reference

```sh
# Before a risky change: a full snapshot, Docker images included
bin/caduceus-backup.sh backup --with-images

# A routine data backup, keeping the newest 14
bin/caduceus-backup.sh backup --keep 14

# See what you have
bin/caduceus-backup.sh list

# Check an archive is intact (checksums and manifest)
bin/caduceus-backup.sh verify backups/caduceus-20261103T211205Z.caduceus.tar

# Roll back to it
bin/caduceus-backup.sh restore backups/caduceus-20261103T211205Z.caduceus.tar \
  --with-images --extract-vendor backups/vendor-restore --start
```

Archives go to `backups/` in the checkout, which is gitignored. To put them somewhere else, use `-o DIR` or set `CADUCEUS_BACKUP_DIR`.

## What is in an archive

An archive is named `<project>-<UTC timestamp>.caduceus.tar`. It is a plain tar file whose members are each gzipped:

| Member | Contents |
| --- | --- |
| `dot-env` | `.env`: secrets and instance settings |
| `config.tgz` | `config/`, including SearXNG settings and any uncommitted edits |
| `docker-compose.yml`, `versions.env` | For reference. Restore does not write them back, because git tracks them. |
| `hermes-data.tgz` | `HERMES_DATA_DIR` (default `data/hermes`): config, sessions, uploads, skills |
| `vault.tgz` | `OBSIDIAN_VAULT_DIR`. Left out with `--no-vault`. |
| `volumes/<name>.tgz` | Every named volume of the project (`hermes-dependencies`, `hermes-matrix-data`, `hermes-mnemosyne-data`, `obsidian-sync-config`, `searxng-valkey-data`) |
| `vendor/<repo>.commit`, `.patch`, `-untracked.tgz` | The commit each `vendor/` checkout is at, plus its local edits. `bin/setup` reclones without them. |
| `images.tar.gz` | Only with `--with-images`: `docker save` of every image the project uses |
| `manifest`, `SHA256SUMS` | What was captured, and checksums for every member |

Things that are deliberately left out:
- The `vendor/` clones themselves. `bin/setup` recreates them from `versions.env`, and the patch puts your edits back on top.
- Container filesystems. Containers are disposable, and everything that lasts lives in the data directory and the volumes above.
- `gateway.sock`. tar prints `pax format cannot archive sockets` for it. That is harmless: it's a live socket that Hermes recreates when it starts.

## Backing up

```sh
bin/caduceus-backup.sh backup [options]
```

1. Stops the running services so the SQLite stores (Matrix, Mnemosyne, obsidian-sync) are captured consistently. This takes about a minute.
2. Archives `.env`, `config/`, the data directory, the vault and the volumes.
3. Starts again the services that were running before.
4. Saves the vendor commits and patches. With `--with-images` it also saves the images, while the stack is already back up.
5. Writes the manifest and checksums, then moves the finished archive into place. A failed run leaves no partial archive behind.

Options:

| Option | Use |
| --- | --- |
| `--with-images` | Include Docker images, about 1.2 GB more. Use it before upgrades and rebuilds. `caduceus-hermes:local` and `caduceus-obsidian-sync:local` are built locally, and the next build overwrites them. |
| `--keep N` | After a backup, delete all but the newest N archives for this project |
| `--no-vault` | Skip the Obsidian vault, for example when you trust Obsidian Sync to hold it |
| `--exclude-volume NAME` | Skip a volume. `hermes-dependencies` (about 750 MB compressed) is a good candidate because `hermes-init` reinstalls it. |
| `--hot` | Don't stop the stack. This is faster, but the SQLite stores may be captured mid-write. |
| `-o DIR` | Write to another directory, such as an external disk or NAS |
| `-C DIR` | Back up another checkout, such as `~/caduceus-dana` |
| `-p NAME` | Override the Compose project name |

Examples:

```sh
# Smaller daily backup without the reinstallable dependencies volume
bin/caduceus-backup.sh backup --exclude-volume hermes-dependencies --keep 7

# Full snapshot to an external drive
bin/caduceus-backup.sh backup --with-images -o /Volumes/Backup/caduceus

# Back up a second instance
bin/caduceus-backup.sh backup -C ~/caduceus-dana
```

Once it finishes, check the archive:

```sh
bin/caduceus-backup.sh verify backups/<archive>
docker compose ps           # every service should be running again
```

## Restoring

```sh
bin/caduceus-backup.sh restore ARCHIVE [options]
```

Restore checks the archive's checksums first. It then shows a summary and asks you to type the project name before it changes anything; pass `--yes` to skip that prompt. After that it:

1. Saves the current `.env` as `.env.pre-restore-<ts>`, if it differs from the archived one, and writes the archived `.env`.
2. Stops the stack.
3. Moves the current data directory and vault aside to `<dir>.pre-restore-<ts>`. They are not deleted.
4. Replaces the contents of each archived volume.
5. Optional steps:
   - writes `config/` back (`--with-config`)
   - loads the images (`--with-images`)
   - copies out the vendor patches (`--extract-vendor DIR`)
   - starts the stack (`--start`)

| Option | Use |
| --- | --- |
| `--with-images` | `docker load` the archived images, putting back the exact `:local` builds |
| `--with-config` | Also overwrite `config/` from the archive. Leave it out if you committed config changes since the backup and want to keep them. |
| `--extract-vendor DIR` | Copy the vendor commits and patches to DIR. Restore then prints the commands that reapply them. |
| `--start` | Run `docker compose up -d` at the end |
| `--no-vault` | Leave the current vault as it is |
| `--exclude-volume NAME` | Leave a volume as it is |
| `--keep-env` | Keep the target checkout's `.env`. Use it when restoring into a different instance. |
| `--yes` | Skip the typed confirmation, for scripts |

### Example: undo a failed upgrade

You upgraded Hermes, rebuilt the image, and something broke. To return to the snapshot exactly:

```sh
bin/caduceus-backup.sh list
bin/caduceus-backup.sh restore backups/caduceus-20261103T211205Z.caduceus.tar \
  --with-images --with-config --extract-vendor backups/vendor-restore --start
```

Then put the `vendor/` source back too, so a later rebuild gives the same image. Restore prints these commands with the real commit filled in:

```sh
git -C vendor/hermes-agent checkout <commit>
git -C vendor/hermes-agent apply backups/vendor-restore/hermes-agent.patch
```

If you also changed tracked files in this repo (`versions.env`, `docker-compose.yml`, `bin/`), roll those back with git. The manifest's `git_commit` line records the commit the snapshot was taken at (`bin/caduceus-backup.sh verify ARCHIVE` prints it).

### Example: data only, keeping the current images

```sh
bin/caduceus-backup.sh restore backups/<archive> --start
```

This brings back conversations, memories, Matrix state and the vault, and runs them on the images you have now. Use it only if the current Hermes build can read the older data.

### Example: restore into another instance

```sh
bin/caduceus-backup.sh restore backups/caduceus-<ts>.caduceus.tar \
  -C ~/caduceus-test --keep-env --start
```

Volumes are mapped by short name, so `caduceus_hermes-mnemosyne-data` lands in `<target>_hermes-mnemosyne-data`. Don't run two instances logged in as the same Matrix bot account, because that breaks end-to-end encryption. Restore warns you about this.

### After a restore

```sh
bin/status && bin/check-integrations
```

Once everything works, delete the leftovers:

```sh
ls -d data/hermes.pre-restore-* "$HOME/obsidian/AI Vault.pre-restore-"* .env.pre-restore-* 2>/dev/null
# remove the ones you no longer need
```

## Good habits

- **Snapshot before every change** with `--with-images`. A full snapshot takes about 2 minutes and is about 2.4 GB.
- **Copy important snapshots off the machine.** `backups/` sits on the same disk as the data it protects.
- **Keep `bin/caduceus-backup.sh` committed**, so a `git checkout` or reset can't remove the tool you need to restore.
- **Archives hold secrets.** `.env` contains API keys and the Matrix password. The script writes archives with mode `600`; store copies just as carefully.
- **`verify` before you rely on an old archive**, especially one that has been copied between disks.
