# tools

Standalone utilities. Not tied to privcloud — use them anywhere.

## backup.sh

rsync wrapper with progress, size summary, and auto sudo fallback.

```bash
# Interactive
./backup.sh

# Direct
./backup.sh /path/to/source /path/to/destination
```

- Shows source size and destination free space before starting
- Append or Mirror mode — append keeps deleted files on backup, mirror removes them
- Incremental — only copies changed/new files after first run
- Auto-retries with sudo if it hits permission-locked files (e.g. Docker-owned directories)
- Fixes ownership after sudo copy so backup is readable without root
- Validates rsync exit code — errors out instead of silently failing
- Requires `rsync`
