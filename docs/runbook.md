# Runbook

One section per alert, named like the alert so the `runbook` annotation links straight to it. Commands assume you are in the repo directory and use the demo container names (`brv-postgres`, `brv-prometheus`). Scripts print to stderr; if you run them from cron, that is whatever file you redirected to.

Exit codes of the two scripts, since most diagnosis starts there:

| Script | Code | Meaning |
|---|---|---|
| backup.sh | 10 | the Postgres container is not running |
| | 11 | `pg_dump` failed, wrote nothing, or the file on disk does not match its checksum |
| | 12 | the control tables could not be read (renamed table, wrong `VERIFY_TABLES`) |
| | 13 | dump is fine, copy to the second location failed |
| | 14 | a backup with the same timestamp already exists |
| verify-restore.sh | 10 | no backup found |
| | 11 | checksum does not match, or the `.sha256` / `.manifest` file is missing |
| | 12 | the temporary container did not start, or `pg_restore` failed |
| | 13 | restore worked, row counts or data checksums differ from the manifest |
| | 14 | the copy in the second location is missing or differs from the primary |

## BackupStale

**Symptom.** No successful backup for more than 26 hours. Cron did not run, the host was down, or the script has been failing since yesterday.

**Check.**

```console
cat data/metrics/backup.prom          # last_run_success, last_success_timestamp_seconds
ls -lt data/backups/primary | head    # newest dump and its date
scripts/backup.sh; echo $?            # run it by hand and read the error
```

If `backup.prom` is fresh and says success but the alert fires, the problem is between the file and Prometheus: see [BackupMetricsAbsent](#backupmetricsabsent).

**Action.** By exit code: 10, start the database container; 11, look at the `pg_dump` error and at `df -h` for the backup directory; 12, check that every name in `VERIFY_TABLES` still exists. Then run `scripts/backup.sh` and `scripts/verify-restore.sh`, and watch the alert clear. If the cause was a missed cron run, check that cron is actually enabled before closing it.

## BackupRunFailed

**Symptom.** The last run failed. Older backups are untouched and rotation did not run, so nothing is lost yet. If nobody fixes it, [BackupStale](#backupstale) follows after 26 hours.

**Check and action.** Same as BackupStale. Run `scripts/backup.sh` by hand, read the exit code from the table above, fix it, run again.

## BackupSecondaryCopyFailed

**Symptom.** The dump is in the primary directory but the copy to the second location failed or did not pass its checksum. Until fixed there is one copy of the newest backup, on one disk.

**Check.**

```console
ls -ld "$SECONDARY_DIR"     # does it exist, is the disk actually mounted
df -h "$SECONDARY_DIR"      # full?
mount | grep -i backup      # adjust to your mount point
```

The script does not create the second directory on purpose, so an unmounted disk shows up as this alert and not as a quiet copy onto the first disk.

**Action.** Fix the mount or the space and run `scripts/backup.sh` again. To avoid taking a new dump, copy the three files of the newest backup (`.dump`, `.dump.sha256`, `.manifest`) with `cp -p` and run `scripts/verify-restore.sh`, which compares the second copy against the primary.

## BackupSizeDropped

**Symptom.** The newest dump is less than half of the 7 day average. The backup technically succeeded, but it may be missing something.

**Check.**

```console
ls -l data/backups/primary/*.dump
head -n 3 data/backups/primary/*.manifest    # row counts per control table over time
```

Did someone purge or archive data? Does `PG_DB` point at the database you think it does?

**Action.** If the shrink is expected, the alert goes away by itself as the average catches up. If not, treat it as data loss in the source: stop rotation from eating the last good dumps (copy the last good one somewhere, raise `MIN_KEEP`) and find out what changed in the source database.

## RestoreVerificationFailed

**Symptom.** The newest backup was not restored successfully or the restored data did not match. This is the alert the whole repo exists for: the backup file exists, but it cannot be relied on.

**Check.** Find the stage that failed.

```console
scripts/verify-restore.sh; echo $?
```

and look the exit code up in the table above. Do not delete the failing backup before you have copied it somewhere, it is the evidence.

**Action.**

- 11: compare both copies, `sha256sum data/backups/*/appdb_*.dump` (`shasum -a 256` on macOS) against the `.sha256` file. If the second copy matches and the primary does not, copy it over the primary. If neither does, take a new backup now and verify it.
- 12: read the `pg_restore` message. `unsupported version` means the throwaway image is older than the server that made the dump, set `VERIFY_IMAGE`. `could not uncompress data` or `unexpected end of file` means the file is damaged. Also check free disk space for Docker.
- 13: the log contains a diff of the manifest against the restored data. One table off by a few rows may just be writes that landed between the dump and the manifest query (see Limitations in the README). Take a new backup at a quiet moment and verify it. A table with far fewer rows, or a different checksum with the same count, is real, and the question becomes why the dump differs from the database.
- 14: copy the missing or different file from the primary to the second location, then run the script again.

A failed verification does not delete anything. Run a new backup and verify it; the alert clears when a verification succeeds.

## RestoreVerificationStale

**Symptom.** No successful verification for more than 50 hours. It is either not running or failing every time (then RestoreVerificationFailed fires too).

**Check.**

```console
cat data/metrics/restore_verification.prom
docker ps -a --filter label=brv.role=restore-verify    # stuck temporary containers
```

**Action.** Make sure the cron entry for verification exists and Docker is up, then run it by hand. A leftover container from a killed run is removed by the next run; to remove it yourself use `docker rm -fv <name>`.

## BackupMetricsAbsent

**Symptom.** Prometheus has no `backup_last_success_timestamp_seconds` or no `restore_verification_success` for 30 minutes. The other alerts cannot fire without data, so this one covers the monitoring itself.

**Check.**

```console
ls -l data/metrics/                                         # two .prom files, mode 644
curl -s localhost:19690/api/v1/targets | grep -o '"health":"[a-z]*"'
curl -s localhost:19690/api/v1/query --data-urlencode 'query=node_textfile_scrape_error'
```

**Action.** Restart node-exporter if it is down. A `.prom` file readable only by its owner (mode 600) is the other common cause; `write_prom` in `scripts/lib.sh` sets 644. If the files do not exist at all, the scripts never ran: run them.

## Restoring for real

The verification restores into a scratch container. When you actually need the data back, restore into a new database next to the old one and look before switching anything:

```console
docker exec brv-postgres createdb -U app appdb_restored
docker exec -i brv-postgres pg_restore -U app -d appdb_restored --no-owner < data/backups/primary/appdb_<timestamp>.dump
docker exec brv-postgres psql -U app -d appdb_restored -c 'SELECT count(*) FROM orders'
```

Compare against `appdb_<timestamp>.manifest` next to the dump, then rename databases or point the application at the restored one.

## Settings

Environment variables read by both scripts (`scripts/lib.sh`):

| Variable | Default | What it does |
|---|---|---|
| `PG_CONTAINER`, `PG_USER`, `PG_DB` | `brv-postgres`, `app`, `appdb` | what gets dumped |
| `VERIFY_TABLES` | `public.customers public.orders public.payments` | tables compared after restore |
| `BACKUP_DIR` | `data/backups/primary` | where dumps go |
| `SECONDARY_DIR` | `data/backups/secondary` | second copy; set to an empty string to turn it off |
| `METRICS_DIR` | `data/metrics` | where the `.prom` files go |
| `RETENTION_DAYS`, `MIN_KEEP` | `7`, `3` | delete dumps older than this, but always keep the newest `MIN_KEEP` |
| `VERIFY_IMAGE` | image of the source container | image used for the throwaway Postgres |

Alert thresholds (26 hours for backups, 50 for verification, half of the 7 day average size) are in `prometheus/rules/backup.yml`. Change them there and update `prometheus/tests/backup_test.yml`.
