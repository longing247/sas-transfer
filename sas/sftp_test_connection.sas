/*
 * sftp_test_connection.sas
 *
 * Sister utility for sftp_upload_manifest.sas.
 *
 * - tests SFTP connectivity using the same SSH-key authentication;
 * - optionally deletes one explicitly named remote file.
 *
 * Set DELETE=Y only when the named remote file should be removed.
 */

%macro sftp_test_connection(
    host=,
    user=,
    remote_dir=,
    keyfile=,
    port=22,
    delete=N,
    file_name=
);
    %local _sftp_options _delete;

    %let _sftp_options=-P &port -i "%superq(keyfile)";
    %let _delete=%upcase(%superq(delete));

    /* Assign the remote directory.  A successful DOPEN confirms that
       SAS can authenticate and access the requested SFTP directory. */
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

    /* Deletion is deliberately opt-in and requires an explicit file name. */
    %if &_delete=Y %then %do;
        %if not %length(%superq(file_name)) %then %do;
            %put ERROR: FILE_NAME is required when DELETE=Y.;
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
    %else %if &_delete ne N %then
        %put ERROR: DELETE must be Y or N.;
%mend sftp_test_connection;


/*
Example: connection test only

%sftp_test_connection(
    host=example.com,
    user=myuser,
    remote_dir=/incoming,
    keyfile=C:\keys\id_rsa
);


Example: test connection and delete one known file

%sftp_test_connection(
    host=example.com,
    user=myuser,
    remote_dir=/incoming,
    keyfile=C:\keys\id_rsa,
    delete=Y,
    file_name=test.txt
);
*/
