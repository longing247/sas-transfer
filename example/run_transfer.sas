/* Example end-to-end workflow */

%include "../sas/prepare_transfer_manifest.sas";
%include "../sas/sftp_upload_manifest.sas";

%let manifest=C:\Transfer\manifest.xlsx;
%let result_xlsx=C:\Transfer\manifest_md5.xlsx;

/*
 * Excel columns:
 *   1 DIRECTORY_PATH
 *   2 FILE_NAME
 *   3 MD5
 *   4 SFTP_TARGET
 *   5 EXTRACT (Y/N)
 *
 * One macro now handles Excel input, validation, MD5, optional extraction,
 * creation of the SFTP-ready SAS dataset, and Excel output.
 */
%prepare_transfer_manifest(
    xlsx=&manifest,
    sheet=Sheet1,
    result_xlsx=&result_xlsx,
    output_sheet=MD5_Result,
    out=work.md5_result,
    directory_col=1,
    file_col=2,
    md5_col=3,
    sftp_target_col=4,
    extract_col=5
);

proc print data=work.md5_result noobs;
run;

/*
 * Each upload run receives a batch ID such as 20260913_001530.
 * A row with SFTP_TARGET=/incoming/study123 is uploaded beneath:
 *
 *     /incoming/study123/20260913_001530/<file>
 *
 * REMOTE_DIR is the fallback base target and the base target for the
 * completed Excel file. The batch directory must already exist remotely.
 */
%sftp_upload_manifest(
    data=work.md5_result,
    excel=&result_xlsx,
    host=sftp.company.com,
    user=myuserid,
    remote_dir=/incoming/study123,
    batch_id=,
    auth=KEY,
    keyfile=C:\Keys\sftp_private.ppk,
    passphrase=,
    port=22,
    out=work.upload_log
);

proc print data=work.upload_log noobs;
run;
