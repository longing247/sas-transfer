/* Example end-to-end workflow */

%include "../sas/prepare_transfer_manifest.sas";
%include "../sas/sftp_upload_manifest.sas";

%let manifest=C:\Transfer\manifest.xlsx;
%let result_manifest=C:\Transfer\manifest_md5.xlsx;
%let batch_id=20260913_001530;

/*
 * Input Excel columns:
 *   1 DIRECTORY_PATH
 *   2 FILE_NAME
 *   3 MD5 (ignored on input; recalculated on output)
 *   4 SFTP_TARGET
 *   5 EXTRACT (may remain in Excel, but is ignored)
 *
 * ZIP behavior is inferred automatically:
 *   ZIP path + FILE_NAME equal to ZIP basename -> transfer whole ZIP
 *   ZIP path + another FILE_NAME              -> extract that member
 */
%prepare_transfer_manifest(
    xlsx=&manifest,
    sheet=Sheet1,
    result_xlsx=&result_manifest,
    out=work.md5_result,
    directory_col=1,
    file_col=2,
    sftp_target_col=4
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
