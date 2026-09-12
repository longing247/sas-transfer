# sas-transfer

SAS utilities for validating files listed in an Excel manifest and transferring the validated package to SFTP.

## Manifest format

The Excel workbook is expected to contain:

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

## ZIP/MD5 validation

`sas/zip_md5_excel.sas` defines `%zip_md5_excel()`.

It:

- imports the Excel manifest;
- scans each distinct ZIP only once;
- searches nested ZIP paths by basename;
- calculates MD5 directly from ZIP members without extracting them;
- calculates MD5 for every matching instance when the same basename appears multiple times;
- accepts duplicate instances only when all MD5 values are identical.

Output statuses:

- `OK` — exactly one matching ZIP member was found and hashed;
- `OK_IDENTICAL_DUPLICATES` — multiple matching members were found and all have the same MD5;
- `NOT_FOUND` — no member with the requested basename was found;
- `MD5_MISMATCH` — multiple matching members have different content;
- `HASH_ERROR` — one or more matching members could not be hashed.

Example:

```sas
%include "sas/zip_md5_excel.sas";

%zip_md5_excel(
    xlsx=C:\Transfer\manifest.xlsx,
    sheet=Sheet1,
    out=work.md5_result
);
```

The output contains:

```text
ZIP_PATH | FILE_NAME | MD5 | STATUS | MATCH_COUNT
```

`HASHING_FILE()` requires SAS 9.4M6 or later.

## SFTP transfer

`sas/sftp_upload_manifest.sas` defines `%sftp_upload_manifest()`.

The macro refuses to upload anything unless every MD5 validation row has status `OK` or `OK_IDENTICAL_DUPLICATES`.

When validation succeeds, it uploads:

1. every distinct ZIP path appearing in the validation dataset; and
2. the Excel manifest itself.

### SSH key authentication — preferred

On Windows, native SAS SFTP uses the PuTTY/PSFTP stack. A PuTTY `.ppk` private key can be supplied with `AUTH=KEY`.

```sas
%include "sas/sftp_upload_manifest.sas";

%sftp_upload_manifest(
    data=work.md5_result,
    excel=C:\Transfer\manifest.xlsx,
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

```sas
%sftp_upload_manifest(
    data=work.md5_result,
    excel=C:\Transfer\manifest.xlsx,
    host=sftp.company.com,
    user=myuserid,
    remote_dir=/incoming/study123,
    auth=PASSWORD,
    password=your_password,
    psftp=C:\Program Files\PuTTY\psftp.exe,
    port=22,
    out=work.upload_log
);
```

**Security:** PSFTP's `-pw` option places the password in the process command line. This may be visible to other processes or system administrators. Use SSH key authentication for unattended or production transfers unless password mode is explicitly permitted by local security policy.

## End-to-end example

See [`example/run_transfer.sas`](example/run_transfer.sas).

The intended workflow is:

```text
Excel manifest
      |
      v
%zip_md5_excel
      |
      +-- validation failure --> STOP
      |
      v
all requested files validated
      |
      v
%sftp_upload_manifest
      |
      +-- unique ZIP files
      +-- Excel manifest
      v
SFTP destination
```
