# gcls - GCS List Recent Files

A bash function utility to list files in Google Cloud Storage (GCS) buckets that have been modified within a specified number of days.

## Overview

`gcls` is a convenient wrapper around `gsutil ls` that filters and displays only recently modified files in a GCS bucket, making it easier to see what files have been added or updated recently.

## Installation

Add the functions to your shell configuration file (`.bashrc`, `.zshrc`, etc.):

```bash
source /path/to/gcls
source /path/to/gcls-large
```

Or simply copy the function definitions into your shell configuration.

## Usage

```bash
gcls <gs://bucket/path/> [days]
```

### Parameters

- **`<gs://bucket/path/>`** (required): The GCS bucket path to list files from
  - Example: `gs://sureshv-ps-jpd-prod-artifactory-storage/filestore/`
  - Can be a bucket root or any subdirectory path
  
- **`[days]`** (optional): Number of days to look back (default: 2 days)
  - Only files modified within the last N days will be shown

### Examples

#### List files modified in the last 5 days
```bash
gcls gs://sureshv-ps-jpd-prod-artifactory-storage/filestore/ 5
```

**Output:**
```
📅 Showing files in gs://sureshv-ps-jpd-prod-artifactory-storage/filestore/ modified within the last 5 days (cutoff: 2025-10-29T06:39:17Z)
     317 B  2025-11-03T04:13:04Z  gs://sureshv-ps-jpd-prod-artifactory-storage/filestore/1c/1c0749c47f6827000ff0b3a25d74b12473b7f0aa
     190 B  2025-11-03T04:32:01Z  gs://sureshv-ps-jpd-prod-artifactory-storage/filestore/12/125c647a8e624a990155d4aee80d8c8c4bcf4621
```

#### List files modified in the last 2 days (default)
```bash
gcls gs://sureshv-ps-jpd-dev-artifactory-storage/
```

#### List files modified in the last 7 days from a specific path
```bash
gcls gs://sureshv-ps-jpd-prod-artifactory-storage/filestore/1c/ 7
```

---

## gcls-large - GCS List Large Recent Files

A complementary utility to `gcls` that focuses on **large files** modified within a specified number of **minutes** (instead of days).

### Overview

`gcls-large` is designed for monitoring large file transfers and uploads. It filters files by both **size** (minimum size threshold) and **time** (recent modifications in minutes), making it ideal for:

- Monitoring large artifact uploads during file transfer testing
- Identifying recently transferred large binaries
- Debugging file transfer issues

### Usage

```bash
gcls-large <gs://bucket/path/> [minutes] [min_size_kb]
```

### Parameters

- **`<gs://bucket/path/>`** (required): The GCS bucket path to list files from
  - Example: `gs://sureshv-ps-jpd-prod-artifactory-storage/filestore/`
  - Can be a bucket root or any subdirectory path
  
- **`[minutes]`** (optional): Number of minutes to look back (default: 30 minutes)
  - Only files modified within the last N minutes will be shown
  
- **`[min_size_kb]`** (optional): Minimum file size in KB (default: 100 KB)
  - Only files larger than this threshold will be shown

### Examples

#### List files > 100KB modified in the last 30 minutes (default)
```bash
gcls-large gs://sureshv-ps-jpd-prod-artifactory-storage/filestore/
```

**Output:**
```
📦 Showing files > 100KB in gs://sureshv-ps-jpd-prod-artifactory-storage/filestore/ modified within the last 30 minutes (cutoff: 2025-11-03T06:20:00Z)
   2.5 MB  2025-11-03T06:25:15Z  gs://sureshv-ps-jpd-prod-artifactory-storage/filestore/4a/4a92626dfaaba74d5616715f473d78d6ac4e0404
   1.2 MB  2025-11-03T06:28:42Z  gs://sureshv-ps-jpd-prod-artifactory-storage/filestore/2d/2d3305a50bf34db9067079c5be2b5e138089ed88
```

#### List files > 500KB modified in the last 5 minutes
```bash
gcls-large gs://sureshv-ps-jpd-dev-artifactory-storage/filestore/ 5 500
```

#### List files > 1MB modified in the last 60 minutes
```bash
gcls-large gs://sureshv-ps-jpd-prod-artifactory-storage/filestore/ 60 1024
```

### Output Format

The output displays:
- **File size** (human-readable: B, KB, MB, GB)
- **Modification timestamp** (ISO 8601 format in UTC)
- **Full GCS path** to the file

Files are automatically sorted by modification time (oldest first).

### Features

- ✅ Filters out directories (only shows files)
- ✅ Size threshold filtering (configurable minimum size)
- ✅ Time-based filtering in minutes (more granular than days)
- ✅ Human-readable file sizes
- ✅ Sorted by modification timestamp (oldest to newest)
- ✅ Works with any GCS bucket path

### Differences from `gcls`

| Feature | `gcls` | `gcls-large` |
|---------|--------|--------------|
| Time unit | Days | Minutes |
| Default time | 2 days | 30 minutes |
| Size filter | None (all files) | Minimum size threshold |
| Default min size | N/A | 100 KB |
| Use case | General recent files | Large file monitoring |

### Use Cases

- **Monitor large file uploads**: See which large artifacts were recently uploaded during file transfer testing
- **Identify transferred files**: Quickly find large files that were copied between JPD buckets
- **Debug transfer issues**: Check which large files were processed during a transfer operation
- **Performance monitoring**: Track large file activity in near real-time

---

## Output Format (gcls)

The output displays:
- **File size** (human-readable: B, KB, MB, GB)
- **Modification timestamp** (ISO 8601 format in UTC)
- **Full GCS path** to the file

Files are automatically sorted by modification time (oldest first).

## Features

- ✅ Filters out directories (only shows files)
- ✅ Human-readable file sizes
- ✅ Sorted by modification timestamp
- ✅ Flexible date range filtering
- ✅ Works with any GCS bucket path

## Use Cases

- **Verify file transfers**: Check if files were successfully copied between buckets
- **Monitor recent uploads**: See what's been added to a bucket recently
- **Troubleshooting**: Identify recently modified files during debugging
- **Audit trails**: Track file changes over time

## Related Commands

For other GCS operations, see:

- `gsutil ls -lrh`: Detailed listing (without date filtering)
- `gsutil cp -r`: Copy files between buckets
- `gsutil rsync`: Synchronize buckets
- `gsutil stat`: Get detailed metadata for a specific file

## Comparison: `gcls` vs Full Listing (ls -ltr equivalent)

### Background

When testing file transfers between JPDs (as documented in `steps_to_test_files_transfer_between_2_jpds.md`), you may need to verify that files were successfully copied. While `gcls` is great for seeing recent files, sometimes you need a full chronological listing of all files.

### `ls -ltr` Equivalent Command

The `ls -ltr` command sorts files by modification time (oldest first to newest last). For GCS buckets, the equivalent command is:

```bash
gsutil ls -lrh gs://sureshv-ps-jpd-prod-artifactory-storage/filestore/ \
  | grep -v '/$' \
  | sort -k2,2 -t'T' -s
```

**Explanation:**
- `gsutil ls -lrh` → Lists all files recursively with human-readable sizes and timestamps
- `grep -v '/$'` → Removes folder entries (since GCS doesn't have real directories)
- `sort -k2,2 -t'T' -s` → Sorts by the 2nd field (timestamp column):
  - `-k2,2` → Sort by the 2nd field (the timestamp column)
  - `-t'T'` → Use 'T' as the field separator (between date and time)
  - `-s` → Stable sort (preserves order when timestamps are identical)

Since GCS timestamps are ISO 8601 UTC strings (YYYY-MM-DDTHH:MM:SSZ), lexicographical sorting naturally gives you chronological order — so this is effectively the same as `ls -ltr` (oldest → newest).

**Example Output:**
```
     317 B  2025-11-03T04:13:04Z  gs://sureshv-ps-jpd-prod-artifactory-storage/filestore/1c/1c0749c47f6827000ff0b3a25d74b12473b7f0aa
     190 B  2025-11-03T04:32:01Z  gs://sureshv-ps-jpd-prod-artifactory-storage/filestore/12/125c647a8e624a990155d4aee80d8c8c4bcf4621
...
     319 B  2025-11-03T05:58:01Z  gs://sureshv-ps-jpd-prod-artifactory-storage/filestore/4d/4d92626dfaaba74d5616715f473d78d6ac4e0404
     306 B  2025-11-03T06:02:01Z  gs://sureshv-ps-jpd-prod-artifactory-storage/filestore/2d/2d3305a50bf34db9067079c5be2b5e138089ed88
TOTAL: 85 objects, 79718337 bytes (76.03 MiB)
```

### Verifying File Metadata

You can confirm file metadata explicitly using:

```bash
gsutil stat gs://sureshv-ps-jpd-prod-artifactory-storage/filestore/2d/2d3305a50bf34db9067079c5be2b5e138089ed88
```

**Output:**
```
    Creation time:          Mon, 03 Nov 2025 06:02:01 GMT
    Update time:            Mon, 03 Nov 2025 06:02:01 GMT
    Storage class:          STANDARD
    Content-Length:         306
    Content-Type:           None
    Hash (crc32c):          k7Vojg==
    Hash (md5):             +cJPkOGAlGDmTNTR61SC9g==
    ETag:                   COW2z6Gn1ZADEAE=
    Generation:             1762149721693029
    Metageneration:         1
```

### When to Use Each Command

- **Use `gcls`**: When you want to quickly see files modified within a recent time window (e.g., after a file transfer operation)
  - Example: `gcls gs://sureshv-ps-jpd-prod-artifactory-storage/filestore/ 5` shows files from last 5 days

- **Use `ls -ltr` equivalent**: When you need a complete chronological listing of all files to compare between source and target buckets
  - Example: Verify all files were copied after running `gsutil rsync` between JPD buckets

### Use Case: Testing File Transfers Between JPDs

When following `steps_to_test_files_transfer_between_2_jpds.md`:

1. **Before transfer**: Use `gcls` on the source bucket to see what files will be transferred
   ```bash
   gcls gs://sureshv-ps-jpd-dev-artifactory-storage/filestore/ 7
   ```

2. **During transfer (monitoring large files)**: Use `gcls-large` to monitor large file uploads in real-time
   ```bash
   # Monitor files > 100KB uploaded in last 5 minutes
   gcls-large gs://sureshv-ps-jpd-prod-artifactory-storage/filestore/ 5 100
   
   # Monitor very large files (> 1MB) in last 30 minutes
   gcls-large gs://sureshv-ps-jpd-prod-artifactory-storage/filestore/ 30 1024
   ```

3. **After `gsutil rsync`**: Use the `ls -ltr` equivalent to verify all files were copied
   ```bash
   # Compare source bucket
   gsutil ls -lrh gs://sureshv-ps-jpd-dev-artifactory-storage/filestore/ | grep -v '/$' | sort -k2,2 -t'T' -s
   
   # Compare target bucket
   gsutil ls -lrh gs://sureshv-ps-jpd-prod-artifactory-storage/filestore/ | grep -v '/$' | sort -k2,2 -t'T' -s
   ```

4. **Verify specific file**: Use `gsutil stat` to check metadata of individual files if needed
   ```bash
   gsutil stat gs://sureshv-ps-jpd-prod-artifactory-storage/filestore/<file-path>
   ```

5. **Quick verification of large transfers**: Use `gcls-large` after transfer to see large files
   ```bash
   # Check large files transferred in last hour
   gcls-large gs://sureshv-ps-jpd-prod-artifactory-storage/filestore/ 60 500
   ```

### Finding Files by Checksum

When testing file transfers, you might only know a file's checksum but need to find its actual path in the Artifactory repository. You can use the JFrog Artifactory REST API to search by checksum.

**Finding a file by SHA1 checksum:**

```bash
jf rt curl "/api/search/checksum?sha1=44c1ff1619699fe7840e31f30fc73c0872d1a759" --server-id=app2
```

**Output:**
```json
{
  "results" : [ {
    "uri" : "http://34.23.57.82/artifactory/api/storage/sv-docker-local/swift-dolphin/v222.1.8_0/list.manifest.json"
  } ]
}
```

This will return the URI of the file in the Artifactory repository, which you can then use to:
- Locate the file in the GCS bucket filestore
- Verify the file was transferred correctly
- Check file metadata or download the file

**Note:** Replace `app2` with your target JPD server ID as configured in JFrog CLI.

**Alternative checksum types:**
- SHA256: `/api/search/checksum?sha256=<hash>`
- MD5: `/api/search/checksum?md5=<hash>`

This is particularly useful when:
- Verifying that specific artifacts were transferred successfully
- Debugging file transfer issues by checking if a file exists in the target JPD
- Locating files that were referenced by checksum in logs or metadata

## Requirements

- `gsutil` command-line tool installed and configured
- `gcloud` authentication set up
- Permissions to list objects in the specified bucket

## Notes

- All timestamps are in UTC
- The function filters out directories (paths ending with `/`)
- Files are sorted chronologically (oldest first)
- If no files match the date range, no output is displayed

