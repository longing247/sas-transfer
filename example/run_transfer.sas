/* Example end-to-end workflow */

%include "../sas/prepare_transfer_manifest.sas";
%include "../sas/sftp_upload_manifest.sas";

%let manifest=C:\Transfer\excel.xlsx;
%let result_manifest=%sysfunc(prxchange(s/\.xlsx$/_md5_%sysfunc(today(),yymmddn8.).xlsx/i,1,&manifest));
%let batch_id=20260913_001530;

/*
 * Actual manifest positions:
 *   1 DIRECTORY_PATH
 *   4 FILE_NAME
 *   6 MD5          (replaced with calculated MD5 in result workbook)
 *   7 SFTP_TARGET
 *
 * Other columns, including any EXTRACT column, are preserved in the result
 * workbook but are not used by the processing logic.
 */
%prepare_transfer_manifest(
    xlsx=&manifest,
    sheet=Sheet1,
    result_xlsx=&result_manifest,
    out=work.md5_result,
    directory_col=1,
    file_col=4,
    md5_col=6,
    sftp_target_col=7
);

proc print data=work.md5_result noobs;
run;

/*
 * Every data row uses its own SFTP_TARGET.
 * REMOTE_DIR is used only for the completed manifest workbook.
 * Remote batch directories must already exist.
 */
%sftp_upload_manifest(
    data=work.md5_result,
    excel=&result_manifest,
    host=sftp.company.com,
    user=myuserid,
    remote_dir=/incoming/study123,
    batch_id=&batch_id,
    keyfile=C:\Keys\sftp_private.ppk,
    passphrase=,
    port=22,
    out=work.upload_log
);

proc print data=work.upload_log noobs;
run;
