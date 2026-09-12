# sas-transfer

SAS utilities for reading a transfer manifest, calculating MD5 values for local files or ZIP members, optionally extracting ZIP members, writing the result, and uploading the resolved files to SFTP.

## Manifest format

The Excel manifest is column-position driven. A typical layout is:

| Column | Field | Meaning |
|---|---|---|
| 1 | `DIRECTORY_PATH` | Either a full path to a `.zip` file or a normal directory path |
| 2 | `FILE_NAME` | File represented by that row |
| 3 | `MD5` | MD5 output column |
| 4 | `SFTP_TARGET` | Base remote SFTP directory for that file |
| 5 | `EXTRACT` | `Y` or `N` |

The source rules are:

1. **ZIP path + `EXTRACT=N`** — `FILE_NAME` must be the basename of the ZIP. The MD5 is calculated on the ZIP file itself and the ZIP is transferred.
2. **ZIP path + `EXTRACT=Y`** — `FILE_NAME` identifies a file inside the ZIP. Its MD5 is calculated directly from the ZIP member, that member is extracted to the SAS WORK area, and only the extracted file is transferred.
3. **Directory path + `EXTRACT=N`** — `FILE_NAME` identifies a file beneath the directory. That file is hashed and transferred.
4. **Directory path + `EXTRACT=Y`** — invalid and raises an error.

Example:

```text
C:\Transfer\study001.zip       study001.zip      <md5>   /incoming/study1   N
C:\Transfer\study002.zip       report.pdf        <md5>   /incoming/study2   Y
C:\Transfer\plain_files        dm.sas7bdat       <md5>   /incoming/study3   N
```

## Excel input/output

`sas/excel_io.sas` defines `%read_manifest_excel()` and `%write_manifest_excel()`.

Example:

```sas
%read_manifest_excel(
    xlsx=C:\Transfer\manifest.xlsx,
    sheet=Sheet1,
    out=work.manifest,
    directory_col=1,
    file_col=2,
    md5_col=3,
    sftp_target_col=4,
    extract_col=5
);
```

The normalized SAS dataset contains:

```text
ROW_ID | DIRECTORY_PATH | FILE_NAME | MD5 | SFTP_TARGET | EXTRACT
```

`%write_manifest_excel()` writes only these manifest-facing fields back to Excel. Internal transfer paths used for extracted ZIP members are not written to the workbook.

## Source MD5 preparation

`sas/source_md5.sas` defines `%source_md5()`.

```sas
%source_md5(
    data=work.manifest,
    out=work.md5_result
);
```

The macro determines whether `DIRECTORY_PATH` points to a ZIP or to a normal directory and applies the rules above.

For extracted ZIP members, nested ZIP folders are searched by basename. If the same basename appears multiple times, every matching member is hashed. Identical duplicates are accepted; duplicates with different MD5 values raise an error.

On success the result includes the manifest fields plus internal fields used by SFTP:

```text
SOURCE_TYPE | TRANSFER_PATH | TRANSFER_NAME
```

`TRANSFER_PATH` is the actual local file SAS should send. For `EXTRACT=Y`, this is the extracted temporary file in the SAS WORK directory.

`HASHING_FILE()` requires SAS 9.4M6 or later.

## SFTP transfer

`sas/sftp_upload_manifest.sas` defines `%sftp_upload_manifest()`.

The macro uploads each unique resolved `TRANSFER_PATH`. The row's `SFTP_TARGET` is treated as a **base remote directory**. `REMOTE_DIR=` is used as a fallback base target and as the base target for the result Excel workbook.

Every invocation receives a batch ID. By default it is generated as:

```text
YYYYMMDD_HHMMSS
```

For example:

```text
20260913_001530
```

The batch ID is appended to the row-level SFTP base target. Therefore:

```text
SFTP_TARGET=/incoming/study123
BATCH_ID=20260913_001530
FILE_NAME=report.pdf
```

is uploaded as:

```text
/incoming/study123/20260913_001530/report.pdf
```

This keeps original filenames unchanged while separating daily runs, retries, and multiple transfers on the same day.

Example:

```sas
%sftp_upload_manifest(
    data=work.md5_result,
    excel=C:\Transfer\manifest_md5.xlsx,
    host=sftp.company.com,
    user=myuserid,
    remote_dir=/incoming/study123,
    batch_id=,
    auth=KEY,
    keyfile=C:\Keys\sftp_private.ppk,
    port=22,
    out=work.upload_log
);
```

Leaving `BATCH_ID=` blank generates it automatically. It can also be supplied explicitly when an external scheduler owns the batch identifier.

The upload log includes:

```text
BATCH_ID | LOCAL_PATH | REMOTE_FILE | UPLOAD_DTTM | STATUS | MESSAGE
```

**Remote directory creation:** the batch directory currently needs to exist on the SFTP server before upload. The native SAS SFTP filename-engine implementation used for `AUTH=KEY` does not create the directory in this macro.

On Windows, `AUTH=KEY` uses the native SAS SFTP filename engine with PuTTY-style key options. `AUTH=PASSWORD` uses an external `psftp.exe` process and requires XCMD permission.

## End-to-end workflow

See `example/run_transfer.sas`.

The workflow is:

1. `%read_manifest_excel()` reads and normalizes the Excel manifest.
2. `%source_md5()` validates each row, calculates MD5, and prepares the actual transfer file.
3. `%write_manifest_excel()` writes the completed manifest.
4. `%sftp_upload_manifest()` generates or accepts a batch ID and uploads each resolved file beneath its batch-specific SFTP target.
