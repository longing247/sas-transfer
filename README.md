# sas-transfer

SAS utilities for preparing a transfer manifest and uploading resolved files to SFTP.

## Manifest format

The current manifest uses these relevant column positions:

| Column | Field | Meaning |
|---|---|---|
| 1 | `DIRECTORY_PATH` | Full path to a `.zip` file or normal directory |
| 4 | `FILE_NAME` | File represented by the row |
| 6 | `MD5` | Replaced with the newly calculated MD5 in the result workbook |
| 7 | `SFTP_TARGET` | Required remote base directory for this file |

All other input columns are preserved. An `EXTRACT` column may remain in the workbook, but it is ignored by the processing logic.

ZIP behavior is inferred automatically:

1. If `DIRECTORY_PATH` points to a ZIP and `FILE_NAME` equals the ZIP basename, hash and transfer the ZIP itself.
2. If `DIRECTORY_PATH` points to a ZIP and `FILE_NAME` is a different filename, find that member in the ZIP, validate duplicate matches by MD5, extract it to SAS `WORK`, and transfer the extracted file.
3. Otherwise, treat `DIRECTORY_PATH` as a normal directory and hash/transfer `DIRECTORY_PATH\FILE_NAME`.

Duplicate ZIP basenames are accepted only when every matching member has the same MD5.

## Manifest preparation

`sas/prepare_transfer_manifest.sas` exposes:

```sas
%prepare_transfer_manifest(
    xlsx=C:\Transfer\manifest.xlsx,
    sheet=Sheet1,
    result_xlsx=C:\Transfer\manifest_md5.xlsx,
    out=work.md5_result,
    directory_col=1,
    file_col=4,
    md5_col=6,
    sftp_target_col=7
);
```

Manifest processing is row based. Each Excel row is validated and processed independently in one DATA step:

```text
row
 -> validate
 -> directory file / whole ZIP: calculate MD5
 -> ZIP member: find, validate duplicate MD5, extract
 -> result row
```

### Format-preserving result workbook

The result workbook is no longer rebuilt with `PROC EXPORT`.

After all manifest rows validate successfully, SAS:

1. copies the original workbook to `RESULT_XLSX=`;
2. opens the copied workbook with the Windows `LIBNAME EXCEL` engine;
3. resolves the configured columns by position;
4. updates only the MD5 cells in the copied sheet.

Because the original workbook is copied first and only cell values in the MD5 column are updated, the workbook keeps its existing formatting, column widths, formulas outside the MD5 cells, filters, frozen panes, other worksheets, and other workbook structure.

`SCANTEXT=NO` is used because the EXCEL engine requires it for updates. `FILELOCK=YES` is used to prevent simultaneous editing by Excel or another application. The workbook should therefore be closed in Excel while the macro runs.

The template MD5 column must be recognized by the EXCEL engine as text/character because MD5 is a 32-character hexadecimal value. If the MD5 column is inferred as numeric, the macro fails and removes the result copy rather than leaving a partially updated workbook. Formatting that column as **Text** in the Excel template is recommended.

This output method requires SAS/ACCESS Interface to PC Files and the Windows EXCEL LIBNAME engine.

MD5 values are taken directly from `HASHING_FILE('MD5', ...)`; no lowercase conversion is applied.

The SFTP-ready SAS dataset remains intentionally canonical:

```text
ROW_ID | DIRECTORY_PATH | FILE_NAME | MD5 | SFTP_TARGET |
SOURCE_TYPE | TRANSFER_PATH | TRANSFER_NAME
```

During processing each row also has `STATUS` and `MESSAGE`. If any row has an error, all errors are logged and the complete preparation step fails. A successful output dataset and result workbook are published only when every row succeeds.

For a ZIP member, `TRANSFER_PATH` points to the extracted temporary file in SAS `WORK`.

`HASHING_FILE()` requires SAS 9.4M6 or later.

## SFTP transfer

`sas/sftp_upload_manifest.sas` exposes:

```sas
%sftp_upload_manifest(
    data=work.md5_result,
    excel=C:\Transfer\manifest_md5.xlsx,
    host=sftp.company.com,
    user=myuserid,
    remote_dir=/incoming/study123,
    batch_id=20260913_001530,
    keyfile=C:\Keys\sftp_private.ppk,
    port=22,
    out=work.upload_log
);
```

The SFTP macro uses key authentication, requires a caller-owned `BATCH_ID`, requires `SFTP_TARGET` for each data file, and uses `REMOTE_DIR` only for the completed manifest workbook. Remote batch directories must already exist.

A data row is uploaded as:

```text
<SFTP_TARGET>/<BATCH_ID>/<TRANSFER_NAME>
```

The completed Excel manifest is uploaded as:

```text
<REMOTE_DIR>/<BATCH_ID>/<manifest file name>
```

The upload log contains:

```text
BATCH_ID | LOCAL_PATH | REMOTE_FILE | UPLOAD_DTTM | STATUS | MESSAGE
```

## End-to-end workflow

See `example/run_transfer.sas`.

The workflow has two public stages:

1. `%prepare_transfer_manifest()` processes the manifest row by row, infers whether ZIP extraction is needed, calculates MD5, creates `work.md5_result`, copies the original workbook, and updates only its MD5 cells through `LIBNAME EXCEL`.
2. `%sftp_upload_manifest()` uploads the resolved files and completed manifest using a caller-supplied batch ID.
