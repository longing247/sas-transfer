/* Example end-to-end workflow */

%include "../sas/excel_io.sas";
%include "../sas/zip_md5_excel.sas";
%include "../sas/sftp_upload_manifest.sas";

%let manifest=C:\Transfer\manifest.xlsx;
%let result_xlsx=C:\Transfer\manifest_md5.xlsx;

/* 1. Read Excel manifest into a standard SAS dataset. */
%read_manifest_excel(
    xlsx=&manifest,
    sheet=Sheet1,
    out=work.manifest
);

/* 2. Validate/hash requested files inside the ZIPs. */
%zip_md5(
    data=work.manifest,
    out=work.md5_result
);

proc print data=work.md5_result noobs;
run;

/* 3. Write the validation result to Excel when required. */
%write_manifest_excel(
    data=work.md5_result,
    xlsx=&result_xlsx,
    sheet=MD5_Result
);

/* 4A. Preferred: SSH key authentication. */
%sftp_upload_manifest(
    data=work.md5_result,
    excel=&result_xlsx,
    host=sftp.company.com,
    user=myuserid,
    remote_dir=/incoming/study123,
    auth=KEY,
    keyfile=C:\Keys\sftp_private.ppk,
    passphrase=,
    port=22,
    out=work.upload_log
);

/*
 * 4B. Optional password authentication using PuTTY PSFTP.
 * Requires XCMD and psftp.exe on the SAS host.
 * Password is exposed in process arguments; use only when approved.
 *
 * %sftp_upload_manifest(
 *     data=work.md5_result,
 *     excel=&result_xlsx,
 *     host=sftp.company.com,
 *     user=myuserid,
 *     remote_dir=/incoming/study123,
 *     auth=PASSWORD,
 *     password=your_password,
 *     psftp=C:\Program Files\PuTTY\psftp.exe,
 *     port=22,
 *     out=work.upload_log
 * );
 */

proc print data=work.upload_log noobs;
run;
