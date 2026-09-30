# SAS Transfer — User Manual

## 1. Purpose

This project prepares files listed in an Excel transfer manifest, calculates MD5 checksums, resolves files stored directly in directories or inside ZIP archives, creates an MD5-populated result workbook, and packages the resolved files into one final ZIP with a companion MD5 CSV.

The current workflow has two main macros:

- `%prepare_transfer` — reads and validates the Excel manifest, resolves each source file, calculates MD5, and creates `work.md5_result`.
- `%package_transfer` — packages the prepared files into subfolders inside the final ZIP and creates the MD5 summary CSV.

## 2. Required working-folder name

The SAS program must be saved and executed from a folder whose final directory name follows:

```text
YYYYMMDD_STUDYID_TAGID
```

Example:

```text
P:\...\20260922_ABC1101-01_ia\program.sas
```

This means:

| Component | Value |
|---|---|
| Date | `20260922` |
| Study ID | `ABC1101-01` |
| Tag ID | `ia` |

`prepare_transfer_manifest.sas` obtains the full SAS program path from the automatic `_SASPROGRAMFILE` macro variable, removes surrounding quotes if present, and creates the global macro variable `program_dir` containing the directory that holds the SAS program.

`package_transfer` parses the final folder name. It does **not** use `TODAY()` for the package name and does not require study ID or tag ID arguments.

The folder name must contain exactly the expected three underscore-separated parts, with an 8-digit first part.

## 3. Excel manifest

By default the following Excel column positions are used:

| Column | Purpose | Required |
|---:|---|---|
| 1 | Source directory or ZIP path | Yes |
| 4 | File name | Yes |
| 6 | MD5 checksum output | Yes |

Other columns are preserved in the exported result workbook.

The actual Excel header text may contain spaces because the program uses:

```sas
options validvarname=any;
```

The macros resolve the required fields by **column position**, not by fixed Excel header names.

### Package subfolder derivation

The package subfolder is derived automatically from the source path; no Data type column is expected in Excel.

```text
source path contains INTERIM\\EXPORT -> RAW_CRF
source path contains INTERIM\\DATA   -> RAW_EXTERNAL
```

If neither path pattern is present, preparation fails because the package destination cannot be determined.

## 4. Supported source-file cases

### Normal directory

If column 1 contains a normal directory:

```text
directory_path = P:\source\data
file_name      = file1.xpt
```

the program reads:

```text
P:\source\data\file1.xpt
```

and calculates its MD5.

### Whole ZIP file

If column 1 itself points to a ZIP and the requested file name equals the ZIP basename:

```text
directory_path = P:\source\archive.zip
file_name      = archive.zip
```

the ZIP itself is the transfer file and its MD5 is calculated.

### File inside a ZIP

If column 1 points to a ZIP but the requested file name is different from the ZIP basename:

```text
directory_path = P:\source\archive.zip
file_name      = file1.xpt
```

the program scans the ZIP for a member whose leaf filename is `file1.xpt`.

The member may be under directories inside the ZIP:

```text
archive.zip
└── folder1/
    └── folder2/
        └── file1.xpt
```

The program calculates the member MD5 and extracts the selected member to SAS `WORK`. The extracted temporary file becomes `transfer_path`.

If multiple ZIP members have the same leaf filename, they are accepted only when their MD5 values are identical. Different MD5 values cause an error.

### Nested ZIP limitation

The program can find and extract an inner ZIP itself:

```text
outer.zip
└── folder1/folder2/folder3/
    └── inner.zip
```

when the manifest requests `inner.zip`.

It does **not** recursively open `inner.zip` to locate another file inside it. Therefore this is not currently supported when the manifest requests `file1.xpt`:

```text
outer.zip
└── folder1/
    └── inner.zip
        └── file1.xpt
```

## 5. Preparing the transfer

Include or run `sas/prepare_transfer_manifest.sas`, then call:

```sas
%prepare_transfer;
```

The default arguments are:

```sas
%prepare_transfer(
    sheet=Sheet1,
    out=work.md5_result,
    directory_col=1,
    file_col=4,
    md5_col=6
);
```

The input workbook name is fixed internally as `template.xlsx`. It must be located in `program_dir`; no workbook-name argument is required.

The result workbook is created in the same program directory using:

```text
template_md5_YYYYMMDD.xlsx
```

The date in this result-workbook filename is the SAS execution date.

### Preparation validation

Each non-empty manifest row is checked. Preparation fails when, for example:

- the configured Excel column position does not exist;
- source directory/ZIP path is missing;
- file name is missing;
- the source path contains neither `INTERIM\\EXPORT` nor `INTERIM\\DATA`;
- a physical source file does not exist;
- a requested ZIP member cannot be found;
- matching duplicate ZIP members have different MD5 values;
- MD5 calculation fails;
- ZIP extraction fails.

If any manifest row has an error, the errors are written to the SAS log and the preparation step does not publish a successful transfer result.

## 6. Prepared SAS dataset

On success, the default output is:

```text
work.md5_result
```

Important generated variables include:

| Variable | Meaning |
|---|---|
| `row_id` | Manifest row sequence |
| `directory_path` | Source directory or ZIP |
| `file_name` | Requested file from the manifest |
| `md5` | Calculated MD5 |
| `source_type` | `DIR` or `ZIP` |
| `transfer_path` | Physical file SAS will put into the package |
| `transfer_name` | Leaf filename |
| `data_type` | Generated package category: `RAW_CRF` or `RAW_EXTERNAL` |
| `relative_path` | Data type folder plus transfer filename |

For example:

```text
transfer_name = file1.xpt
data_type     = RAW_CRF
relative_path = RAW_CRF/file1.xpt
```

`transfer_path` and `relative_path` serve different purposes. `transfer_path` identifies the physical source/extracted file. `relative_path` identifies where that file belongs inside the final package.

## 7. Creating the final package

After `%prepare_transfer` succeeds, run:

```sas
%package_transfer;
```

or explicitly:

```sas
%package_transfer(
    data=work.md5_result
);
```

No date, study ID, or tag ID arguments are required.

For a program directory:

```text
P:\...\20260922_ABC1101-01_ia
```

the outputs are:

```text
20260922_ABC1101-01_ia.zip
20260922_ABC1101-01_ia_md5.csv
```

Both are written to `program_dir`.

If a ZIP with the same package filename already exists, the macro removes it before creating the new package.

## 8. Final ZIP structure

`relative_path` is used as the ZIP member path.

For files whose source paths map to the two supported categories, the final package can contain:

the final package is:

```text
20260922_ABC1101-01_ia.zip
├── RAW_CRF/
│   ├── file1.xpt
│   └── file2.xpt
└── RAW_EXTERNAL/
    └── file3.csv
```

`RAW_CRF` is selected for source paths containing `INTERIM\\EXPORT`; `RAW_EXTERNAL` is selected for paths containing `INTERIM\\DATA`.

## 9. MD5 summary CSV

After the ZIP is complete, `package_transfer` calculates the MD5 of the final ZIP.

The summary CSV contains only the final package MD5:

```csv
file_name,md5
20260922_ABC1101-01_ia.zip,<package_md5>
```

Individual file MD5 values are still calculated during preparation and written to the sister Excel result workbook for inspection. They are not repeated in the package summary CSV.

## 10. Typical end-to-end program

A typical calling program is:

```sas
/* Load the macro definitions as appropriate for your SAS environment. */

%prepare_transfer;

%package_transfer;
```

The calling `.sas` file should be located in the correctly named transfer folder, for example:

```text
20260922_ABC1101-01_ia/
├── program.sas
├── template.xlsx
├── template_md5_20260924.xlsx            <- created by prepare_transfer
├── 20260922_ABC1101-01_ia.zip            <- created by package_transfer
└── 20260922_ABC1101-01_ia_md5.csv        <- created by package_transfer
```

Source files referenced by the Excel manifest may be elsewhere.

## 11. Important operational notes

The SAS environment must provide `_SASPROGRAMFILE`. If it is empty, `program_dir` cannot be derived and the SAS log reports an error.

The current implementation uses `HASHING_FILE('MD5', ...)` and the SAS ZIP filename engine. Binary ZIP-member extraction uses binary record handling to avoid truncating binary files such as XPT files.

The result Excel workbook is generated with `PROC EXPORT DBMS=XLSX`. It preserves the input column order in the exported dataset and replaces the configured MD5 column with the calculated value, but it should not be treated as a byte-for-byte or formatting-preserving copy of the source workbook.

Do not rename or move the calling SAS program to a folder that does not follow the package naming convention before running `package_transfer`.

## 12. Troubleshooting

**`_SASPROGRAMFILE is empty`** — The SAS client/session has not supplied the path of the executing SAS program. Confirm that the code is being executed from a saved SAS program rather than an unsaved editor buffer.

**`Program folder must follow YYYYMMDD_STUDYID_TAGID`** — Rename or move the program folder to the required convention, for example `20260922_ABC1101-01_ia`.

**`One or more requested Excel column indexes do not exist`** — Confirm that the imported worksheet has at least the configured columns and that the correct sheet is being read.

**`Cannot determine data type from source path`** — The source path contains neither `INTERIM\\EXPORT` nor `INTERIM\\DATA`. Confirm that the manifest points to a supported source location.

**`Source file does not exist`** — Check the directory path and filename in the manifest and confirm the SAS server can access that location.

**`Requested file not found in ZIP`** — The program scanned the outer ZIP but found no member with the requested leaf filename.

**`Duplicate ZIP members have different MD5 values`** — More than one member has the requested leaf filename and the contents differ. The manifest does not uniquely identify which file should be transferred.

**Package MD5 cannot be calculated** — Check the preceding ZIP creation log for errors and confirm the output directory is writable.

## 13. Current scope

The implemented workflow covers manifest preparation, MD5 calculation, direct files, whole ZIPs, files located in folders inside ZIPs, path-derived `RAW_CRF` / `RAW_EXTERNAL` package subfolders, final ZIP creation, and MD5 CSV creation.

Recursive traversal into ZIP files contained inside another ZIP is not currently implemented.
