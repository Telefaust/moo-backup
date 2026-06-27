# Moodle plugins (Moo-backup)

## local_backupnotice

Site-wide banner while `dataroot/backup-notice.json` exists.

| Artifact | Path |
|----------|------|
| Install ZIP | `dist/local_backupnotice_moodle40-*.zip` |
| Source | [`local/backupnotice/`](local/backupnotice/) |
| Documentation | [`local/backupnotice/README.md`](local/backupnotice/README.md) |

## quizaccess_backupnotice

Quiz access rule: blocks **new** attempts while `backup-notice.json` exists (`prevent_new_attempt` only). In-progress attempts are not affected.

| Artifact | Path |
|----------|------|
| Install ZIP | `dist/quizaccess_backupnotice_moodle40-*.zip` |
| Source | [`quizaccess/backupnotice/`](quizaccess/backupnotice/) |
| Moodle path | `mod/quiz/accessrule/backupnotice/` |

Install via **Site administration → Plugins → Install plugins**. Plugin type: **Quiz access rule**, folder **`backupnotice`**.

Rebuild both ZIPs after changes:

```bash
python build-zip.py
```

The archive root must contain `backupnotice/` with forward-slash paths only.
