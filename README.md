# sas-transfer

SAS utilities for preparing a transfer manifest and uploading resolved files to SFTP.

## Manifest format

The input Excel layout is intentionally simple and column-position driven:

| Column | Field | Meaning |
|---|---|---|
| 1 | `DIRECTORY_PATH` | Full path to a `.zip` file or normal directory |
| 2 | `FILE_NAME` | File represented by the row |
| 3 | `MD5` | Ignored on input; recalculated in the result workbook |
| 4 | `SFTP_TARGET` | Required remote base directory for this file |
| 5 | `EXTRACT` | `Y` or `N` |

Source rules:

1. **ZIP + `EXTRACT=N`** — `FILE_NAME` must equal the ZIP basename. Hash and transfer the ZIP.
2. **ZIP + `EXTRACT=Y`** — find `FILE_NAME` inside the ZIP, hash it, extract it to SAS `WORK`, and transfer only that file.
3. **Directory + `EXTRACT=N`** — hash and transfer `DIRECTORY_PATH\FILE_NAME`.
4. **Directory + `EXTRACT=Y`** — invalid.

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
    file_col=2,
    sftp_target_col=4,
    extract_col=5
);
```

The macro now keeps only the flexibility that is useful for this workflow:

- headers are always expected;
- the four required input fields are selected by column index;
- `SFTP_TARGET` is mandatory;
- MD5 is always recalculated rather than read from Excel;
- the original workbook is never modified;
- the completed manifest is written with a simple `PROC EXPORT`.

Column-index resolution is isolated in the internal `%_pm_resolve_columns()` helper so the main macro stays focused on the processing flow.

Invalid rows and direct files are handled in one DATA step. ZIP processing remains separate because it requires member enumeration, duplicate-MD5 validation and optional extraction.

The SFTP-ready dataset contains:

```text
ROW_ID | DIRECTORY_PATH | FILE_NAME | MD5 | SFTP_TARGET | EXTRACT |
SOURCE_TYPE | TRANSFER_PATH | TRANSFER_NAME
```

`TRANSFER_PATH` is the actual local file to upload. For `EXTRACT=Y`, it points to the extracted temporary file in SAS `WORK`.

If any row fails validation, the whole preparation step fails and no successful output dataset or completed workbook is produced.

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

The SFTP macro is intentionally opinionated:

- key authentication only;
- `BATCH_ID=` is required and is owned by the caller;
- each data file must have its own `SFTP_TARGET`;
- `REMOTE_DIR=` is used only for the completed manifest workbook;
- remote batch directories must already exist.

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

1. `%prepare_transfer_manifest()` validates the input, calculates MD5, optionally extracts ZIP members, creates `work.md5_result`, and writes the completed manifest workbook.
2. `%sftp_upload_manifest()` uploads the resolved files and completed manifest using a caller-supplied batch ID.
