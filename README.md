# sas-transfer

SAS utilities for preparing a transfer manifest and uploading the resolved files to SFTP.

## Manifest format

The Excel manifest is column-position driven. A typical layout is:

| Column | Field | Meaning |
|---|---|---|
| 1 | `DIRECTORY_PATH` | Either a full path to a `.zip` file or a normal directory path |
| 2 | `FILE_NAME` | File represented by that row |
| 3 | `MD5` | MD5 output column updated in place |
| 4 | `SFTP_TARGET` | Base remote SFTP directory for that file |
| 5 | `EXTRACT` | `Y` or `N` |

Source rules:

1. **ZIP path + `EXTRACT=N`** — `FILE_NAME` must be the ZIP basename. MD5 is calculated on the ZIP itself and the ZIP is transferred.
2. **ZIP path + `EXTRACT=Y`** — `FILE_NAME` identifies a file inside the ZIP. Its MD5 is calculated from the ZIP member, that member is extracted to the SAS WORK directory, and only that extracted file is transferred.
3. **Directory path + `EXTRACT=N`** — `FILE_NAME` identifies a file beneath the directory. That file is hashed and transferred.
4. **Directory path + `EXTRACT=Y`** — invalid and raises an error.

Example:

```text
C:\Transfer\study001.zip       study001.zip      <md5>   /incoming/study1   N
C:\Transfer\study002.zip       report.pdf        <md5>   /incoming/study2   Y
C:\Transfer\plain_files        dm.sas7bdat       <md5>   /incoming/study3   N
```

## Manifest preparation

`sas/prepare_transfer_manifest.sas` defines one public macro:

```sas
%prepare_transfer_manifest(
    xlsx=C:\Transfer\manifest.xlsx,
    sheet=Sheet1,
    out=work.md5_result,
    directory_col=1,
    file_col=2,
    md5_col=3,
    sftp_target_col=4,
    extract_col=5
);
```

The macro:

- reads the existing Excel sheet;
- maps columns by their configured positions;
- validates the manifest rules;
- distinguishes ZIP sources from normal directories;
- calculates MD5 for direct files and ZIP members;
- scans each ZIP needed for extraction only once;
- accepts duplicate ZIP members only when all matching MD5 values are identical;
- extracts one validated member to SAS `WORK` when `EXTRACT=Y`;
- creates the SFTP-ready SAS output dataset;
- updates only the configured MD5 column in the original workbook after the whole batch passes validation.

The output dataset contains:

```text
ROW_ID | DIRECTORY_PATH | FILE_NAME | MD5 | SFTP_TARGET | EXTRACT |
SOURCE_TYPE | TRANSFER_PATH | TRANSFER_NAME
```

`TRANSFER_PATH` is the actual local file that SFTP should send. For `EXTRACT=Y`, it points to the extracted temporary file in SAS `WORK`.

If any row fails validation, the macro logs all detected errors and does not update the workbook or leave a successful output dataset behind.

### Excel update behavior

The same input workbook is updated in place; no separate result workbook is created. The macro uses the Windows SAS `EXCEL` LIBNAME engine because the `XLSX` engine cannot update individual worksheet values. `SCANTEXT=NO` enables update access and `FILELOCK=YES` prevents simultaneous editing.

Close the workbook in Microsoft Excel before running the SAS job. Other worksheets are left intact and only the MD5 values in the selected sheet are updated.

This implementation therefore requires Windows SAS with SAS/ACCESS Interface to PC Files available. `HASHING_FILE()` requires SAS 9.4M6 or later.

## SFTP transfer

`sas/sftp_upload_manifest.sas` defines `%sftp_upload_manifest()`.

The macro uploads each unique resolved `TRANSFER_PATH`. The row's `SFTP_TARGET` is treated as a base remote directory. `REMOTE_DIR=` is used as a fallback base target and as the base target for the completed manifest workbook.

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

Example:

```sas
%sftp_upload_manifest(
    data=work.md5_result,
    excel=C:\Transfer\manifest.xlsx,
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

The batch directory currently needs to exist on the SFTP server before upload.

On Windows, `AUTH=KEY` uses the native SAS SFTP filename engine with PuTTY-style key options. `AUTH=PASSWORD` uses an external `psftp.exe` process and requires XCMD permission.

## End-to-end workflow

See `example/run_transfer.sas`.

The workflow has two public stages:

1. `%prepare_transfer_manifest()` reads the original Excel manifest, validates sources, calculates MD5, optionally extracts ZIP members, produces `work.md5_result`, and fills the MD5 column in that same workbook.
2. `%sftp_upload_manifest()` generates or accepts a batch ID and uploads the resolved files plus the updated manifest beneath their batch-specific SFTP targets.
