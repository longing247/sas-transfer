# sas-transfer

SAS utilities for reading a transfer manifest, validating files inside ZIP archives with MD5, writing validation results, and uploading the validated package to SFTP.

## Manifest format

The input Excel workbook is expected to contain:

| Column | Meaning |
|---|---|
| 1 | Full Windows path to a ZIP file |
| 2 | File name to locate inside that ZIP |

The target file may be located in any nested directory inside the ZIP.

Example:

```text
C:\Transfer\study001.zip    dm.sas7bdat
C:\Transfer\study001.zip    ae.sas7bdat
C:\Transfer\study002.zip    report.pdf
```

## Excel input and output

`sas/excel_io.sas` defines two reusable macros.

### `%read_manifest_excel()`

Reads the first two Excel columns and converts them into a standard SAS dataset with:

```text
ROW_ID | ZIP_PATH | FILE_NAME
```

Example:

```sas
%include "sas/excel_io.sas";

%read_manifest_excel(
    xlsx=C:\Transfer\manifest.xlsx,
    sheet=Sheet1,
    out=work.manifest
);
```

### `%write_manifest_excel()`

Writes a SAS dataset to an Excel workbook.

Example:

```sas
%write_manifest_excel(
    data=work.md5_result,
    xlsx=C:\Transfer\manifest_md5.xlsx,
    sheet=MD5_Result
);
```

Excel I/O is deliberately separated from ZIP/MD5 validation so the validation logic can also be used with SAS datasets created by other processes.

## ZIP/MD5 validation

`sas/zip_md5_excel.sas` now defines `%zip_md5()`.

The macro no longer reads or writes Excel. It accepts a SAS input dataset containing `ZIP_PATH` and `FILE_NAME` and produces a SAS result dataset.

It:

- scans each distinct ZIP only once;
- searches nested ZIP paths by basename;
- calculates MD5 directly from ZIP members without extracting them;
- calculates MD5 for every matching instance when the same basename appears multiple times;
- accepts duplicate instances only when all MD5 values are identical.

Example:

```sas
%zip_md5(
    data=work.manifest,
    out=work.md5_result
);
```

The output contains:

```text
ROW_ID | ZIP_PATH | FILE_NAME | MD5 | STATUS | MATCH_COUNT
```

Output statuses:

- `OK` — exactly one matching ZIP member was found and hashed;
- `OK_IDENTICAL_DUPLICATES` — multiple matching members were found and all have the same MD5;
- `NOT_FOUND` — no member with the requested basename was found;
- `MD5_MISMATCH` — multiple matching members have different content;
- `HASH_ERROR` — one or more matching members could not be hashed.

`HASHING_FILE()` requires SAS 9.4M6 or later.

## SFTP transfer

`sas/sftp_upload_manifest.sas` defines `%sftp_upload_manifest()`.

The macro refuses to upload anything unless every MD5 validation row has status `OK` or `OK_IDENTICAL_DUPLICATES`.

When validation succeeds, it uploads every distinct ZIP file appearing in the validation dataset plus the Excel result file.

### SSH key authentication — preferred

On Windows, native SAS SFTP uses the PuTTY/PSFTP stack. A PuTTY `.ppk` private key can be supplied with `AUTH=KEY`.

```sas
%sftp_upload_manifest(
    data=work.md5_result,
    excel=C:\Transfer\manifest_md5.xlsx,
    host=sftp.company.com,
    user=myuserid,
    remote_dir=/incoming/study123,
    auth=KEY,
    keyfile=C:\Keys\sftp_private.ppk,
    passphrase=,
    port=22,
    out=work.upload_log
);
```

### Username/password authentication

`AUTH=PASSWORD` uses an external PuTTY `psftp.exe` process and therefore requires SAS `XCMD` permission and PSFTP installed on the SAS host.

**Security:** PSFTP's `-pw` option places the password in the process command line. Use SSH key authentication for unattended or production transfers unless password mode is explicitly permitted by local security policy.

## End-to-end example

See [`example/run_transfer.sas`](example/run_transfer.sas).

The workflow is now separated into four stages:

1. `%read_manifest_excel()` reads the Excel manifest into `work.manifest`.
2. `%zip_md5()` validates the requested files and calculates MD5 values.
3. `%write_manifest_excel()` writes the validation result to a new Excel file.
4. `%sftp_upload_manifest()` checks that validation succeeded and uploads the unique ZIP files plus the result Excel file.

This separation keeps external file I/O independent from the ZIP validation logic and makes each macro reusable on its own.
