/*
 * sftp_test_connection.sas
 *
 * Sister utility for sftp_upload_manifest.sas.
 *
 * - tests SFTP connectivity using the same SSH-key authentication;
 * - optionally deletes one explicitly named remote file;
 * - optionally deletes one explicitly named empty remote folder.
 *
 * Deletion is opt-in.
 */

%macro sftp_test_connection(
    host=,
    user=,
    remote_dir=,
    keyfile=,
    port=22,
    delete_file=N,
    file_name=,
    delete_folder=N,
    folder_name=
);
    %local _sftp_options _delete_file _delete_folder;

    %let _sftp_options=-P &port -i "%superq(keyfile)";
    %let _delete_file=%upcase(%superq(delete_file));
    %let _delete_folder=%upcase(%superq(delete_folder));

    filename sftptest SFTP "%superq(remote_dir)"
        host="&host"
        user="&user"
        optionsx="&_sftp_options";

    data _null_;
        length message $500;
        did=dopen('sftptest');

        if did>0 then do;
            putlog 'NOTE: SFTP connection successful.';
            rc=dclose(did);
        end;
        else do;
            message=sysmsg();
            putlog 'ERROR: SFTP connection failed. ' message;
        end;
    run;

    filename sftptest clear;

    /* Delete one explicitly named remote file. */
    %if &_delete_file=Y %then %do;
        %if not %length(%superq(file_name)) %then %do;
            %put ERROR: FILE_NAME is required when DELETE_FILE=Y.;
            %return;
        %end;

        filename sftpdel SFTP
            "%sysfunc(prxchange(s/\/+$/,,%superq(remote_dir)))/%superq(file_name)"
            host="&host"
            user="&user"
            recfm=n
            optionsx="&_sftp_options";

        data _null_;
            length message $500;

            if fexist('sftpdel') then do;
                rc=fdelete('sftpdel');

                if rc=0 then
                    putlog "NOTE: SFTP file deleted: %superq(file_name)";
                else do;
                    message=sysmsg();
                    putlog 'ERROR: SFTP file could not be deleted. ' message;
                end;
            end;
            else
                putlog "ERROR: SFTP file does not exist: %superq(file_name)";
        run;

        filename sftpdel clear;
    %end;
    %else %if &_delete_file ne N %then
        %put ERROR: DELETE_FILE must be Y or N.;

    /* Delete one explicitly named empty remote folder. */
    %if &_delete_folder=Y %then %do;
        %if not %length(%superq(folder_name)) %then %do;
            %put ERROR: FOLDER_NAME is required when DELETE_FOLDER=Y.;
            %return;
        %end;

        filename sftpdir SFTP "%superq(remote_dir)"
            host="&host"
            user="&user"
            optionsx="&_sftp_options";

        data _null_;
            length message $500;
            did=dopen('sftpdir');

            if did>0 then do;
                rc=ddelete("%superq(folder_name)",did);

                if rc=0 then
                    putlog "NOTE: SFTP folder deleted: %superq(folder_name)";
                else do;
                    message=sysmsg();
                    putlog 'ERROR: SFTP folder could not be deleted. '
                           'The folder must be empty. ' message;
                end;

                rc_close=dclose(did);
            end;
            else do;
                message=sysmsg();
                putlog 'ERROR: SFTP parent directory could not be opened. ' message;
            end;
        run;

        filename sftpdir clear;
    %end;
    %else %if &_delete_folder ne N %then
        %put ERROR: DELETE_FOLDER must be Y or N.;
%mend sftp_test_connection;


/*
Example: connection test only

%sftp_test_connection(
    host=example.com,
    user=myuser,
    remote_dir=/incoming,
    keyfile=C:\keys\id_rsa
);


Example: delete one known file

%sftp_test_connection(
    host=example.com,
    user=myuser,
    remote_dir=/incoming,
    keyfile=C:\keys\id_rsa,
    delete_file=Y,
    file_name=test.txt
);


Example: delete an empty folder /incoming/test_batch

%sftp_test_connection(
    host=example.com,
    user=myuser,
    remote_dir=/incoming,
    keyfile=C:\keys\id_rsa,
    delete_folder=Y,
    folder_name=test_batch
);
*/
