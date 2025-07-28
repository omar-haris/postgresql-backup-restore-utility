# PostgreSQL Backup & Restore Utility

A single‑file Bash script that:

* **Backs up** a PostgreSQL database as a compressed `pg_dump` archive
* **Optionally restores** the dump to another server / database
* **Optionally uploads** the dump to **Amazon S3**
* **Self‑installs missing tools** (`pg_dump`, `pg_restore`, `psql`, `awscli`, …) on all major Linux distributions

> **Why?** For dev prod snapshots, one‑button staging refreshes, nightly cloud backups, CI pipelines, and when you just want to ship a dump without touching the source box again.



## Supported Linux distributions

* Debian / Ubuntu / Pop!\_OS / Linux Mint (APT)
* RHEL / CentOS / Rocky Linux / AlmaLinux (YUM or DNF)
* Fedora (DNF)
* Arch Linux / Manjaro (Pacman)
* openSUSE Leap / Tumbleweed (Zypper)
* Alpine Linux (APK)

Other distros work as long as the required binaries are in `$PATH`.

---

## Installation

```bash
# 1 – Clone the repository
git clone https://github.com/omar-haris/postgresql-backup-restore-utility.git
cd postgresql-backup-restore-utility
chmod +x postgres_backup_restore.sh

# 2 – (Optional) Move to a directory that's inside $PATH
sudo cp postgres_backup_restore.sh /usr/local/bin/pg‑bak
```

> **Note** : The script auto‑installs any missing tools at runtime. You only need `bash` and a compatible package manager.

---

## Quick start

1. Ensure the **source** Postgres server is reachable and you have credentials.
2. Run:

```bash
./postgres_backup_restore.sh \
    --src-host db.prod.internal \
    --src-db   app_prod \
    --src-pass "$PGPASSWORD"
```

3. Grab the dump from `/home/backups/app_prod_YYYYmmdd_HHMMSS.dump`.

---

## Command‑line options

Run `./postgres_backup_restore.sh --help` any time.

```text
-r, --restore                Restore to destination DB after dumping
-s, --s3-upload              Upload dump to Amazon S3 after dumping
-b, --backup-dir DIR         Local folder for dumps [ /home/backups ]

Source overrides:
     --src-host HOST          Source host [127.0.0.1]
     --src-port PORT          Source port [5432]
     --src-user USER          Source user [postgres]
     --src-db   DB            Source database [mydb]
     --src-pass PASS          Source password [changeme]

Destination overrides (restore):
     --dest-host HOST         Destination host [192.168.1.99]
     --dest-port PORT         Destination port [5432]
     --dest-user USER         Destination user [postgres]
     --dest-db   DB           Destination database [mydb_restore]
     --dest-pass PASS         Destination password [changeme]

S3 overrides (upload):
     --s3-bucket  NAME        Bucket name [my-bucket]
     --s3-prefix  PREFIX      Key prefix/folder [ "" ]
     --aws-cli    PATH        Custom awscli binary [aws]
```

---

## Examples

### 1 – Plain backup to `/srv/dumps`

```bash
./postgres_backup_restore.sh -b /srv/dumps
```

### 2 – Backup *and* restore to staging

```bash
./postgres_backup_restore.sh -r \
    --src-host db.prod \
    --dest-host db.staging \
    --dest-db   app_staging
```

### 3 – Nightly cron job with S3 upload

```cron
0 2 * * * /usr/local/bin/pg-bak \
    -s --s3-bucket org-prod-pg-dumps \
    --s3-prefix  nightly/ \
    --src-db     app_prod \
    --src-pass   "$PGPASSWORD" >> /var/log/pg-bak.log 2>&1
```

---

## Automatic dependency install

The first time you run the script, it checks for:

* `pg_dump`, `pg_restore`, `psql`, `createdb`
* `aws` (only if `-s / --s3-upload` is set)

If any are missing, the script:

1. Detects your package manager (APT, DNF, YUM, Pacman, Zypper, APK).
2. Installs the corresponding packages (e.g. `postgresql-client`, `awscli`).
3. Verifies the binaries are now available.

> **Root required** : You’ll be prompted for `sudo` if you’re not running as root. If sudo isn’t available, the script aborts with a clear error.

---

## Environment variables

| Variable                                                     | Purpose                                                            |
| ------------------------------------------------------------ | ------------------------------------------------------------------ |
| `PGPASSWORD`                                                 | Used by PostgreSQL tools when set by the script internally       |
| `AWS_PROFILE` / `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY` | Standard awscli auth                                               |

---

## Security notes

* Backups contain **all data & blobs** — encrypt if piping outside trusted networks.
* Consider adding `openssl enc -aes256` or GPG encryption when writing to disk or before S3 upload.
* Store credentials in environment variables or a `.pgpass` file instead of CLI flags to avoid them showing up in process lists.

---

## License

MIT — see [LICENSE](LICENSE) for details. Attribution appreciated ♥️ .
