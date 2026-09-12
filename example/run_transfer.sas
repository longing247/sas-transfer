/* Example end-to-end workflow */

%include "../sas/excel_io.sas";
%include "../sas/source_md5.sas";
%include "../sas/sftp_upload_manifest.sas";

%let manifest=C:\Transfer\manifest.xlsx;
%let result_xlsx=C:\Transfer\manifest_md5.xlsx;

/*
 * Example Excel columns:
 *   1 DIRECTORY_PATH
 *   2 FILE_NAME
 *   3 MD5
 *   4 SFTP_TARGET
 *   5 EXTRACT (Y/N)
 */
%read_manifest_excel(
    xlsx=&manifest,
    sheet=Sheet1,
    out=work.manifest,
    directory_col=1,
    file_col=2,
    md5_col=3,
    sftp_target_col=4,
    extract_col=5
);

/* Resolve source type, validate rules, calculate MD5 and prepare transfer files. */
%source_md5(
    data=work.manifest,
    out=work.md5_result
);

proc print data=work.md5_result noobs;
run;

/* Write only the manifest-facing fields back to Excel. */
%write_manifest_excel(
    data=work.md5_result,
    xlsx=&result_xlsx,
    sheet=MD5_Result
);

/* Preferred: SSH key authentication. Row SFTP_TARGET is used per file.
   REMOTE_DIR is a fallback and is also the destination for the Excel result. */
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

proc print data=work.upload_log noobs;
run;
