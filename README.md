# PostgreSQL Backup & Restore Utility

<div align="center">

![PostgreSQL Backup Tool](postgresql-backup-restore-tool.png)

**A powerful single-file Bash script for PostgreSQL database operations with cloud integration**

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Bash](https://img.shields.io/badge/Shell-Bash-blue.svg)](https://www.gnu.org/software/bash/)
[![PostgreSQL](https://img.shields.io/badge/PostgreSQL-Compatible-blue.svg)](https://www.postgresql.org/)
[![S3 Compatible](https://img.shields.io/badge/S3-Compatible-orange.svg)](https://aws.amazon.com/s3/)

</div>

## ✨ **Key Features**

✅ **Backup** PostgreSQL databases as compressed `pg_dump` archives  
✅ **Restore** dumps to any PostgreSQL server  
✅ **Upload** backups to Amazon S3 or S3-compatible storage (MinIO, etc.)  
✅ **Clean up** old backup files with configurable retention policies  
✅ **Auto-install** missing dependencies on all major Linux distributions  
✅ **Flexible modes** for backup-only, restore-only, or S3-only operations  
✅ **Smart selection** with automatic latest backup detection  
✅ **Cross-platform** support for major Linux distributions  
✅ **Security-focused** with environment variable support  

> **Perfect for:** Dev/prod snapshots, staging refreshes, nightly cloud backups, CI/CD pipelines, disaster recovery workflows, and database migrations.

---

## 🚀 **Quick Start**

### **Basic Operations**

```bash
# Clone and setup
git clone https://github.com/omar-haris/postgresql-backup-restore-utility.git
cd postgresql-backup-restore-utility
chmod +x postgres_backup_restore.sh

# Basic backup
./postgres_backup_restore.sh --src-host db.prod.com --src-db myapp

# Backup + restore to staging
./postgres_backup_restore.sh -r \
    --src-host prod.db.com --src-db myapp_prod \
    --dest-host staging.db.com --dest-db myapp_staging

# Backup + upload to S3 + cleanup
./postgres_backup_restore.sh -s \
    --src-host prod.db.com --src-db myapp \
    --s3-bucket my-backups --cleanup-local 24h
```

---

## 🖥️ **Supported Systems**

<div align="center">

| Distribution | Package Manager | Status |
|---|---|---|
| **Debian/Ubuntu/Pop!_OS/Mint** | APT | ✅ Fully Supported |
| **RHEL/CentOS/Rocky/Alma** | YUM/DNF | ✅ Fully Supported |
| **Fedora** | DNF | ✅ Fully Supported |
| **Arch/Manjaro** | Pacman | ✅ Fully Supported |
| **openSUSE Leap/Tumbleweed** | Zypper | ✅ Fully Supported |
| **Alpine Linux** | APK | ✅ Fully Supported |

</div>

The script automatically detects your system and installs required tools (`pg_dump`, `pg_restore`, `psql`, `s3cmd`) on first run.

---

## 🎯 **Operation Modes**

### **Overview**

Choose from these flexible operation modes to fit your workflow:

```bash
┌─────────────────┬──────────────────────────────────────────┐
│ Mode            │ Description                              │
├─────────────────┼──────────────────────────────────────────┤
│ Default         │ Create backup, then optionally restore/ │
│                 │ upload (original behavior)               │
├─────────────────┼──────────────────────────────────────────┤
│ --backup-only   │ Only create backup (skip restore/S3)    │
├─────────────────┼──────────────────────────────────────────┤
│ --restore-only  │ Only restore from existing backup       │
├─────────────────┼──────────────────────────────────────────┤
│ --s3-only       │ Only upload existing backup to S3       │
├─────────────────┼──────────────────────────────────────────┤
│ --cleanup-only  │ Only run cleanup operations             │
└─────────────────┴──────────────────────────────────────────┘
```

### **1. Default Mode (Backup + Optional Actions)**

**Create backup with optional restore and/or S3 upload:**

```bash
# Simple backup
./postgres_backup_restore.sh --src-db myapp

# Backup + restore to staging
./postgres_backup_restore.sh -r \
    --src-db production --dest-db staging

# Backup + S3 upload
./postgres_backup_restore.sh -s \
    --src-db myapp --s3-bucket daily-backups

# Complete workflow: backup + restore + S3 + cleanup
./postgres_backup_restore.sh -r -s \
    --src-db production --dest-db staging \
    --s3-bucket backups --cleanup-local 48h --cleanup-s3 168h
```

### **2. Backup-Only Mode**

**Create backups without restore or S3 operations:**

```bash
# Basic backup-only
./postgres_backup_restore.sh --backup-only --src-db myapp

# Custom backup location
./postgres_backup_restore.sh --backup-only \
    --src-db myapp --backup-dir /srv/backups

# Multiple databases backup
for db in app1 app2 app3; do
    ./postgres_backup_restore.sh --backup-only \
        --src-db "$db" --backup-dir "/backups/$db"
done
```

### **3. Restore-Only Mode**

**Restore from existing backups without creating new ones:**

```bash
# Restore latest local backup
./postgres_backup_restore.sh --restore-only \
    --src-db myapp --dest-db myapp_restored

# Restore specific backup file
./postgres_backup_restore.sh --restore-only \
    --restore-file myapp_20240125_143022.dump \
    --dest-db myapp_restored

# Download and restore from S3
./postgres_backup_restore.sh --restore-only --restore-from-s3 \
    --src-db myapp --dest-db myapp_from_s3 \
    --s3-bucket my-backups
```

### **4. S3-Only Mode**

**Upload existing backups to S3 without creating new ones:**

```bash
# Upload latest backup to S3
./postgres_backup_restore.sh --s3-only \
    --src-db myapp --s3-bucket archive-storage

# Upload with S3 cleanup
./postgres_backup_restore.sh --s3-only \
    --src-db myapp --s3-bucket backups --cleanup-s3 168h
```

### **5. Cleanup-Only Mode**

**Clean up old files without backup operations:**

```bash
# Clean local files older than 24 hours
./postgres_backup_restore.sh --cleanup-local 24h

# Clean S3 files older than 7 days
./postgres_backup_restore.sh --cleanup-s3 168h

# Clean both local and S3
./postgres_backup_restore.sh --cleanup-local 48h --cleanup-s3 336h
```

---

## 📋 **Command Reference**

Run `./postgres_backup_restore.sh --help` for complete options.

### **Operation Modes**
```bash
[default]                    # Create backup, then optionally restore/upload
--backup-only                # Only create backup
--restore-only               # Only restore from existing backup
--s3-only                    # Only upload existing backup to S3
--cleanup-only               # Only run cleanup operations
```

### **Actions**
```bash
-r, --restore                # Restore to destination after backup
-s, --s3-upload              # Upload to S3 after backup
    --cleanup-local TIME     # Remove local backups older than TIME
    --cleanup-s3 TIME        # Remove S3 backups older than TIME
-b, --backup-dir DIR         # Backup directory [default: /home/backups]
```

### **Restore Options**
```bash
--restore-file FILE          # Restore specific backup file
--restore-from-s3            # Download and restore from S3
```

### **Database Connection**

**Source (backup from):**
```bash
--src-host HOST              # Source hostname [default: 127.0.0.1]
--src-port PORT              # Source port [default: 5432]
--src-user USER              # Source username [default: postgres]
--src-db   DATABASE          # Source database [default: mydb]
--src-pass PASSWORD          # Source password [default: changeme]
```

**Destination (restore to):**
```bash
--dest-host HOST             # Destination hostname [default: 192.168.1.99]
--dest-port PORT             # Destination port [default: 5432]
--dest-user USER             # Destination username [default: postgres]
--dest-db   DATABASE         # Destination database [default: mydb_restore]
--dest-pass PASSWORD         # Destination password [default: changeme]
```

### **S3 Configuration**
```bash
--s3-bucket NAME             # S3 bucket name
--s3-prefix PREFIX           # S3 key prefix/folder [default: ""]
--s3-endpoint URL            # Custom S3 endpoint (for MinIO, etc.)
--s3-access-key KEY          # AWS Access Key ID
--s3-secret-key KEY          # AWS Secret Access Key
```

---

## 🔧 **Real-World Use Cases**

### **Production Workflows**

#### **Daily Production Backup**
```bash
./postgres_backup_restore.sh -s \
    --src-host prod-db.company.com \
    --src-db production_app \
    --src-pass "$PGPASSWORD" \
    --s3-bucket prod-backups \
    --s3-prefix daily/ \
    --cleanup-local 72h \
    --cleanup-s3 720h
```

#### **Cross-Server Database Migration**
```bash
./postgres_backup_restore.sh -r \
    --src-host old-server.com --src-db legacy_app \
    --dest-host new-server.com --dest-db migrated_app \
    --dest-user new_db_user
```

#### **Staging Environment Refresh**
```bash
./postgres_backup_restore.sh --restore-only --restore-from-s3 \
    --src-db production_app \
    --dest-host staging-db.company.com \
    --dest-db staging_app \
    --s3-bucket prod-backups \
    --s3-prefix daily/
```

### **Development Workflows**

#### **Local Development Setup**
```bash
./postgres_backup_restore.sh --restore-only \
    --src-db production_app \
    --dest-host localhost \
    --dest-db dev_app \
    --dest-user dev_user
```

#### **Feature Branch Testing**
```bash
./postgres_backup_restore.sh --restore-only \
    --restore-file production_app_20240125_120000.dump \
    --dest-host test-server \
    --dest-db feature_branch_test
```

### **Disaster Recovery**

#### **Emergency Restore from S3**
```bash
./postgres_backup_restore.sh --restore-only --restore-from-s3 \
    --src-db critical_app \
    --dest-host disaster-recovery-server \
    --dest-db critical_app_restored \
    --s3-bucket disaster-backups
```

#### **Point-in-Time Recovery**
```bash
./postgres_backup_restore.sh --restore-only \
    --restore-file critical_app_20240125_120000.dump \
    --dest-host emergency-server \
    --dest-db critical_app_emergency
```

### **CI/CD Integration**

#### **Automated Testing Pipeline**
```bash
# In your CI/CD pipeline
./postgres_backup_restore.sh --restore-only \
    --restore-from-s3 \
    --src-db production \
    --dest-host ci-db \
    --dest-db test_db_${CI_BUILD_ID} \
    --s3-bucket test-data
```

#### **Release Preparation**
```bash
# Create pre-release backup
./postgres_backup_restore.sh -s \
    --src-db production \
    --s3-bucket release-backups \
    --s3-prefix v${VERSION}/
```

---

## ⏰ **Automation with Cron**

### **Production Schedules**

**Daily Backup with Cloud Archive:**
```cron
# Daily backup at 2 AM with S3 upload and cleanup
0 2 * * * /usr/local/bin/postgres_backup_restore.sh -s \
    --src-db production --s3-bucket daily-backups \
    --cleanup-local 72h --cleanup-s3 720h \
    >> /var/log/pg-backup.log 2>&1
```

**Weekly Archive to Cold Storage:**
```cron
# Weekly archive on Sundays at 3 AM
0 3 * * 0 /usr/local/bin/postgres_backup_restore.sh --s3-only \
    --src-db production --s3-bucket weekly-archive \
    --s3-prefix weekly/$(date +%Y%m)/ \
    >> /var/log/pg-archive.log 2>&1
```

**Daily Staging Refresh:**
```cron
# Refresh staging every day at 6 AM
0 6 * * * /usr/local/bin/postgres_backup_restore.sh --restore-only \
    --restore-from-s3 --src-db production --dest-db staging \
    --s3-bucket daily-backups \
    >> /var/log/staging-refresh.log 2>&1
```

### **Development Schedules**

**Nightly Test Data Refresh:**
```cron
# Refresh test database nightly
0 1 * * * /usr/local/bin/postgres_backup_restore.sh --restore-only \
    --restore-from-s3 --src-db production --dest-db test_data \
    --dest-host test-server --s3-bucket sanitized-backups \
    >> /var/log/test-refresh.log 2>&1
```

---

## 📂 **File Naming & Selection Logic**

### **Backup File Format**
```
database_YYYYMMDD_HHMMSS.dump
```

### **Examples**
```
myapp_20240124_120000.dump  ← older
myapp_20240125_090000.dump  ← middle  
myapp_20240125_143022.dump  ← latest (auto-selected)
```

### **Selection Priority**
1. **`--restore-file` specified** → use exact file
2. **`--restore-from-s3`** → download latest from S3
3. **Default** → use latest in backup directory by timestamp

### **Smart Detection Algorithm**
- Parses timestamp from filename
- Converts to epoch time for accurate comparison
- Selects highest timestamp value
- Validates file integrity before operations

---

## 🔐 **Security Best Practices**

### **Environment Variables**
```bash
# Set sensitive data as environment variables
export PGPASSWORD="your-secure-password"
export S3_ACCESS_KEY="your-access-key"
export S3_SECRET_KEY="your-secret-key"

# Use in script
./postgres_backup_restore.sh \
    --src-pass "$PGPASSWORD" \
    --s3-access-key "$S3_ACCESS_KEY" \
    --s3-secret-key "$S3_SECRET_KEY"
```

### **PostgreSQL Password File**
```bash
# Create .pgpass file for password-less authentication
echo "hostname:port:database:username:password" >> ~/.pgpass
chmod 600 ~/.pgpass

# Script automatically uses .pgpass when available
./postgres_backup_restore.sh --src-host prod-db --src-db myapp
```

### **S3 Credentials Management**
```bash
# Option 1: AWS CLI configuration
aws configure set aws_access_key_id YOUR_ACCESS_KEY
aws configure set aws_secret_access_key YOUR_SECRET_KEY

# Option 2: Instance roles (recommended for EC2)
# No credentials needed - uses IAM role

# Option 3: Environment variables
export AWS_ACCESS_KEY_ID="your-key"
export AWS_SECRET_ACCESS_KEY="your-secret"
```

---

## 🌐 **S3 & Cloud Storage Support**

### **AWS S3**
```bash
./postgres_backup_restore.sh -s \
    --s3-bucket production-backups \
    --s3-prefix db-backups/ \
    --s3-access-key AKIAIOSFODNN7EXAMPLE \
    --s3-secret-key wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY
```

### **MinIO (Self-hosted)**
```bash
./postgres_backup_restore.sh -s \
    --s3-bucket backups \
    --s3-endpoint minio.company.com:9000 \
    --s3-access-key minioaccess \
    --s3-secret-key miniosecret
```

### **Digital Ocean Spaces**
```bash
./postgres_backup_restore.sh -s \
    --s3-bucket my-spaces \
    --s3-endpoint nyc3.digitaloceanspaces.com \
    --s3-access-key YOUR_SPACES_KEY \
    --s3-secret-key YOUR_SPACES_SECRET
```

### **Wasabi Cloud Storage**
```bash
./postgres_backup_restore.sh -s \
    --s3-bucket my-wasabi-bucket \
    --s3-endpoint s3.wasabisys.com \
    --s3-access-key YOUR_WASABI_KEY \
    --s3-secret-key YOUR_WASABI_SECRET
```

---

## 🧹 **Advanced Cleanup Strategies**

### **Retention Policies**

**Grandfather-Father-Son Strategy:**
```bash
# Daily backups (keep 7 days)
0 2 * * * /path/to/script -s --s3-prefix daily/ --cleanup-local 168h

# Weekly backups (keep 4 weeks)  
0 2 * * 0 /path/to/script -s --s3-prefix weekly/ --cleanup-s3 672h

# Monthly backups (keep 12 months)
0 2 1 * * /path/to/script -s --s3-prefix monthly/ --cleanup-s3 8760h
```

**Simple Retention:**
```bash
# Keep local backups for 3 days, S3 backups for 30 days
./postgres_backup_restore.sh -s \
    --cleanup-local 72h \
    --cleanup-s3 720h
```

---

## 🚨 **Troubleshooting Guide**

### **Common Issues & Solutions**

#### **Connection Issues**
```bash
# Test database connectivity
psql -h your-host -U your-user -d postgres -c "SELECT version();"

# Check firewall/network
telnet your-db-host 5432
```

#### **Permission Issues**
```bash
# Ensure script is executable
chmod +x postgres_backup_restore.sh

# Check backup directory permissions
mkdir -p /home/backups
chmod 755 /home/backups
```

#### **S3 Connectivity Issues**
```bash
# Test S3 connection manually
s3cmd ls s3://your-bucket/

# Verify credentials
s3cmd --access_key=YOUR_KEY --secret_key=YOUR_SECRET ls s3://your-bucket/
```

#### **File Not Found Errors**
```bash
# List available backup files
ls -la /home/backups/*.dump

# Use absolute path for specific files
./postgres_backup_restore.sh --restore-only \
    --restore-file /full/path/to/backup.dump
```

### **Debugging Mode**
```bash
# Run with debug output
bash -x ./postgres_backup_restore.sh --help

# Check dependencies
./postgres_backup_restore.sh --help | head -20
```

### **Log Analysis**
```bash
# Monitor backup logs
tail -f /var/log/pg-backup.log

# Check system logs for errors
journalctl -u cron -f
```

---

## 📊 **Monitoring & Alerting**

### **Log Monitoring**
```bash
# Setup log rotation
cat > /etc/logrotate.d/pg-backup << EOF
/var/log/pg-backup.log {
    daily
    missingok
    rotate 30
    compress
    create 644 postgres postgres
}
EOF
```

### **Success/Failure Notifications**
```bash
# Add to script wrapper
#!/bin/bash
if ./postgres_backup_restore.sh "$@"; then
    echo "Backup successful" | mail -s "DB Backup Success" admin@company.com
else
    echo "Backup failed" | mail -s "DB Backup FAILED" admin@company.com
fi
```

---

## 🛠️ **Installation Options**

### **Option 1: Clone Repository**
```bash
git clone https://github.com/omar-haris/postgresql-backup-restore-utility.git
cd postgresql-backup-restore-utility
chmod +x postgres_backup_restore.sh
```

### **Option 2: Direct Download**
```bash
curl -O https://raw.githubusercontent.com/omar-haris/postgresql-backup-restore-utility/main/postgres_backup_restore.sh
chmod +x postgres_backup_restore.sh
```

### **Option 3: System-wide Installation**
```bash
sudo cp postgres_backup_restore.sh /usr/local/bin/pg-backup
sudo chmod +x /usr/local/bin/pg-backup

# Now use system-wide
pg-backup --help
```

### **Option 4: Docker Usage**
```bash
# Create a Dockerfile
FROM postgres:latest
RUN apt-get update && apt-get install -y s3cmd
COPY postgres_backup_restore.sh /usr/local/bin/
RUN chmod +x /usr/local/bin/postgres_backup_restore.sh
```

---

## 🔄 **Integration Examples**

### **Kubernetes CronJob**
```yaml
apiVersion: batch/v1
kind: CronJob
metadata:
  name: postgres-backup
spec:
  schedule: "0 2 * * *"
  jobTemplate:
    spec:
      template:
        spec:
          containers:
          - name: backup
            image: postgres:latest
            command:
            - /bin/bash
            - -c
            - |
              curl -O https://raw.githubusercontent.com/omar-haris/postgresql-backup-restore-utility/main/postgres_backup_restore.sh
              chmod +x postgres_backup_restore.sh
              ./postgres_backup_restore.sh -s \
                --src-host $PG_HOST \
                --src-db $PG_DATABASE \
                --s3-bucket $S3_BUCKET
            env:
            - name: PGPASSWORD
              valueFrom:
                secretKeyRef:
                  name: postgres-secret
                  key: password
          restartPolicy: OnFailure
```

### **Terraform Module**
```hcl
module "postgres_backup" {
  source = "./modules/postgres-backup"
  
  cron_schedule = "0 2 * * *"
  s3_bucket     = "production-backups"
  db_host       = aws_rds_cluster.main.endpoint
  db_name       = "production"
}
```

### **Ansible Playbook**
```yaml
---
- name: Setup PostgreSQL Backup
  hosts: db-servers
  tasks:
    - name: Download backup script
      get_url:
        url: https://raw.githubusercontent.com/omar-haris/postgresql-backup-restore-utility/main/postgres_backup_restore.sh
        dest: /usr/local/bin/pg-backup
        mode: '0755'
    
    - name: Setup daily backup cron
      cron:
        name: "Daily PostgreSQL Backup"
        minute: "0"
        hour: "2"
        job: "/usr/local/bin/pg-backup -s --s3-bucket {{ backup_bucket }}"
```

---

## 🧪 **Testing & Validation**

### **Backup Integrity Testing**
```bash
# Test backup creation
./postgres_backup_restore.sh --backup-only --src-db test_db

# Validate backup file
pg_restore --list /home/backups/test_db_*.dump

# Test restore to temporary database
./postgres_backup_restore.sh --restore-only \
    --src-db test_db --dest-db test_db_validate
```

### **S3 Upload Testing**
```bash
# Test S3 connectivity
./postgres_backup_restore.sh --s3-only \
    --src-db test_db --s3-bucket test-bucket

# Verify upload
s3cmd ls s3://test-bucket/
```

### **End-to-End Testing**
```bash
# Complete workflow test
./postgres_backup_restore.sh -r -s \
    --src-db source_test \
    --dest-db destination_test \
    --s3-bucket test-bucket \
    --cleanup-local 1h
```

---

## 🤝 **Contributing**

We welcome contributions! Here's how you can help:

### **Reporting Issues**
- Use the [GitHub Issues](https://github.com/omar-haris/postgresql-backup-restore-utility/issues) page
- Provide detailed error messages and system information
- Include steps to reproduce the issue

### **Submitting Changes**
1. Fork the repository
2. Create a feature branch (`git checkout -b feature/amazing-feature`)
3. Commit your changes (`git commit -m 'Add amazing feature'`)
4. Push to the branch (`git push origin feature/amazing-feature`)
5. Open a Pull Request

### **Development Guidelines**
- Follow existing code style
- Add comments for complex logic
- Test on multiple Linux distributions
- Update documentation for new features

---

## 📚 **Additional Resources**

- **[PostgreSQL Documentation](https://www.postgresql.org/docs/)**
- **[s3cmd Documentation](https://s3tools.org/s3cmd)**
- **[AWS S3 Documentation](https://docs.aws.amazon.com/s3/)**
- **[MinIO Documentation](https://docs.min.io/)**

---

## 📄 **License**

MIT License

Copyright (c) 2025 Omar Haris

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.

---

<div align="center">

**Questions?** Open an [issue](https://github.com/omar-haris/postgresql-backup-restore-utility/issues) or check our [documentation](https://github.com/omar-haris/postgresql-backup-restore-utility/wiki).

**⭐ Found this useful? Give it a star!**

</div>

