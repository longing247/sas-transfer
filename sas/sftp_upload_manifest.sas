/*
 * sftp_upload_manifest.sas
 *
 * Upload all unique ZIP files listed in a validated SAS result dataset,
 * plus the Excel manifest itself, to one SFTP destination.
 *
 * Windows/SAS notes:
 * - AUTH=KEY uses the native SAS SFTP filename engine and a PuTTY .ppk key.
 * - AUTH=PASSWORD uses PuTTY psftp.exe and requires XCMD permission.
 * - Password mode places the password in the PSFTP process arguments; use it
 *   only if permitted by local security policy. KEY mode is preferred.
 */

%macro sftp_upload_manifest(
    data=,
    excel=,
    host=,
    user=,
    remote_dir=,
    auth=KEY,
    keyfile=,
    passphrase=,
    password=,
    psftp=psftp.exe,
    port=22,
    out=work.sftp_upload_log
);

    %local _auth _transfer_failures;
    %let _auth=%upcase(%superq(auth));

    /* Never transfer if MD5 validation contains a failure. */
    proc sql noprint;
        select count(*)
          into :_transfer_failures trimmed
          from &data
         where status not in ('OK','OK_IDENTICAL_DUPLICATES');
    quit;

    %if &_transfer_failures > 0 %then %do;
        %put ERROR: Transfer aborted because &_transfer_failures validation row(s) failed.;
        data &out;
            length local_path $1024 remote_file $2048 status $40 message $500;
            status='VALIDATION_FAILED';
            message=cats('Upload aborted: ',"&_transfer_failures",' manifest row(s) failed validation.');
            output;
        run;
        %return;
    %end;

    /* Unique ZIP files from the manifest plus the Excel manifest itself. */
    proc sort
        data=&data(keep=zip_path where=(not missing(zip_path)))
        out=work._upload_files
        nodupkey;
        by zip_path;
    run;

    data work._upload_files;
        set work._upload_files end=eof;
        length local_path $1024;
        local_path=zip_path;
        output;

        if eof then do;
            local_path="&excel";
            output;
        end;

        keep local_path;
    run;

    %if &_auth = KEY %then %do;

        data &out;
            set work._upload_files;
            length filename_only $512 remote_file $2048
                   localref $8 remoteref $8 status $40 message $500
                   sftp_options $2048;

            filename_only=scan(local_path,-1,'\/');
            remote_file=cats(prxchange('s/\/+$/','1',strip("&remote_dir")),'/',filename_only);
            localref='localf';
            remoteref='remotef';

            rc_local=filename(localref,local_path);
            if rc_local ne 0 then do;
                status='LOCAL_FILE_ERROR';
                message=sysmsg();
                output;
                rc_clear=filename(localref);
                return;
            end;

            sftp_options=cats('-P &port -i ',quote(strip("&keyfile")));
            %if %length(%superq(passphrase)) %then %do;
                sftp_options=cats(sftp_options,' -pw ',quote("&passphrase"));
            %end;

            rc_remote=filename(
                remoteref,
                remote_file,
                'SFTP',
                cats(
                    'host=',quote("&host"),' ',
                    'user=',quote("&user"),' ',
                    'recfm=s ',
                    'optionsx=',quote(trim(sftp_options))
                )
            );

            if rc_remote ne 0 then do;
                status='SFTP_ASSIGN_ERROR';
                message=sysmsg();
            end;
            else do;
                rc_copy=fcopy(localref,remoteref);
                if rc_copy=0 then do;
                    status='UPLOADED';
                    message='';
                end;
                else do;
                    status='UPLOAD_ERROR';
                    message=sysmsg();
                end;
            end;

            rc1=filename(localref);
            rc2=filename(remoteref);
            output;

            keep local_path remote_file status message;
        run;

    %end;
    %else %if &_auth = PASSWORD %then %do;

        /*
         * Native Windows SAS SFTP is key-oriented. Password mode therefore
         * uses PuTTY PSFTP with a temporary batch file containing one PUT.
         * This requires XCMD and psftp.exe on the SAS host.
         */
        filename _sftpbatch temp;

        data &out;
            set work._upload_files;
            length filename_only $512 remote_file $2048 status $40 message $500
                   batch_path $1024 cmd $4096 batch_line $4096;

            filename_only=scan(local_path,-1,'\/');
            remote_file=cats(prxchange('s/\/+$/','1',strip("&remote_dir")),'/',filename_only);
            batch_path=pathname('_sftpbatch');

            /* Rewrite the temporary PSFTP batch file for this upload. */
            fid=fopen('_sftpbatch','O');
            if fid=0 then do;
                status='BATCH_FILE_ERROR';
                message=sysmsg();
                output;
                return;
            end;

            batch_line=cats('put ',quote(strip(local_path)),' ',quote(strip(remote_file)));
            rc_fput=fput(fid,batch_line);
            rc_write=fwrite(fid);
            rc_close=fclose(fid);

            if rc_fput ne 0 or rc_write ne 0 or rc_close ne 0 then do;
                status='BATCH_FILE_ERROR';
                message=sysmsg();
                output;
                return;
            end;

            /*
             * SECURITY: -pw exposes the password to the process command line.
             * Prefer AUTH=KEY for unattended/production use.
             */
            cmd=cats(
                quote(strip("&psftp")),
                ' -batch -P &port',
                ' -l ',quote(strip("&user")),
                ' -pw ',quote("&password"),
                ' -b ',quote(strip(batch_path)),' ',
                quote(strip("&host"))
            );

            rc_system=system(cmd);

            if rc_system=0 then do;
                status='UPLOADED';
                message='';
            end;
            else do;
                status='UPLOAD_ERROR';
                message=cats('PSFTP exit code=',rc_system);
            end;

            output;
            keep local_path remote_file status message;
        run;

        filename _sftpbatch clear;

    %end;
    %else %do;
        %put ERROR: AUTH must be KEY or PASSWORD.;
        data &out;
            length local_path $1024 remote_file $2048 status $40 message $500;
            status='INVALID_AUTH_MODE';
            message='AUTH must be KEY or PASSWORD.';
            output;
        run;
    %end;

    proc datasets library=work nolist;
        delete _upload_files;
    quit;

%mend sftp_upload_manifest;
