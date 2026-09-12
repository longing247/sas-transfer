# sas-transfer

SAS utilities for preparing a transfer manifest and uploading the resolved files to SFTP.

## Manifest format

The Excel manifest is column-position driven:

| Column | Field | Meaning |
|---|---|---|
| 1 | `DIRECTORY_PATH` | Full path to a `.zip` file or a normal directory |
| 2 | `FILE_NAME` | File represented by the row |
| 3 | `MD5` | MD5 result |
| 4 | `SFTP_TARGET` | Base remote SFTP directory |
| 5 | `EXTRACT` | `Y` or `N` |

Source rules:

1. **ZIP + `EXTRACT=N`** — `FILE_NAME` must equal the ZIP basename. Hash and transfer the ZIP.
2. **ZIP + `EXTRACT=Y`** — find `FILE_NAME` inside the ZIP, hash it, extract it to SAS `WORK`, and transfer only that file.
3. **Directory + `EXTRACT=N`** — hash and transfer `DIRECTORY_PATH\FILE_NAME`.
4. **Directory + `EXTRACT=Y`** — invalid.

For duplicate basenames inside a ZIP, all matching members are hashed. Identical duplicates are accepted; different MD5 values raise an error.

## Manifest preparation

`sas/prepare_transfer_manifest.sas` exposes one macro:

```sas
%prepare_transfer_manifest(
    xlsx=C:\Transfer\manifest.xlsx,
    sheet=Sheet1,
    result_xlsx=C:\Transfer\manifest_md5.xlsx,
    out=work.md5_result,
    directory_col=1,
    file_col=2,
    md5_col=3,
    sftp_target_col=4,
    extract_col=5
);
```

The `*_col` arguments are column indexes. The macro reads the input workbook, validates the manifest, calculates MD5 values, performs requested ZIP extraction, creates the SFTP-ready SAS dataset, and writes a completed manifest to `RESULT_XLSX=`.

The original workbook is not modified. Writing the result is deliberately implemented with a simple `PROC EXPORT`, avoiding Excel update engines, workbook locking, and in-place cell-update logic.

The SFTP-ready dataset contains:

```text
ROW_ID | DIRECTORY_PATH | FILE_NAME | MD5 | SFTP_TARGET | EXTRACT |
SOURCE_TYPE | TRANSFER_PATH | TRANSFER_NAME
```

`TRANSFER_PATH` is the actual local file to upload. For `EXTRACT=Y`, it points to the extracted temporary file in SAS `WORK`.

If any row fails validation, errors are logged and no successful output dataset or completed result workbook is produced by that run.

`HASHING_FILE()` requires SAS 9.4M6 or later.

## SFTP transfer

`sas/sftp_upload_manifest.sas` defines `%sftp_upload_manifest()`.

The macro uploads each unique resolved `TRANSFER_PATH`. The row's `SFTP_TARGET` is the base remote directory; `REMOTE_DIR=` is the fallback and the base target for the completed manifest workbook.

Each invocation generates a batch ID in `YYYYMMDD_HHMMSS` format unless `BATCH_ID=` is supplied. For example:

```text
SFTP_TARGET=/incoming/study123
BATCH_ID=20260913_001530
FILE_NAME=report.pdf

-> /incoming/study123/20260913_001530/report.pdf
```

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

The upload log contains:

```text
BATCH_ID | LOCAL_PATH | REMOTE_FILE | UPLOAD_DTTM | STATUS | MESSAGE
```

The batch directory currently needs to exist on the SFTP server before upload.

On Windows, `AUTH=KEY` uses the native SAS SFTP filename engine with PuTTY-style key options. `AUTH=PASSWORD` uses `psftp.exe` and requires XCMD permission.

## End-to-end workflow

See `example/run_transfer.sas`.

The workflow has two public stages:

1. `%prepare_transfer_manifest()` reads and validates the input manifest, calculates MD5, optionally extracts ZIP members, produces `work.md5_result`, and writes a separate completed manifest workbook.
2. `%sftp_upload_manifest()` uploads the resolved files plus the completed manifest beneath their batch-specific SFTP targets.
