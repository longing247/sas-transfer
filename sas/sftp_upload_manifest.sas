/*
 * sftp_upload_manifest.sas
 *
 * Upload all unique ZIP files listed in a validated SAS result dataset,
 * plus the Excel manifest itself, to one SFTP destination.
 *
 * Windows/SAS notes:
 * - KEY mode uses the native SAS SFTP filename engine and a PuTTY .ppk key.
 * - PASSWORD mode uses an external psftp.exe command and therefore requires
 *   XCMD permission. Passwords supplied on a command line may be visible to
 *   the OS process list; KEY mode is strongly preferred for automation.
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

    %local _auth;
    %let _auth=%upcase(%superq(auth));

    /* Upload only after validation has no failure status. */
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
            local_path='';
            remote_file='';
            status='VALIDATION_FAILED';
            message=cats('Upload aborted: ',"&_transfer_failures",' manifest row(s) failed validation.');
            output;
        run;
        %return;
    %end;

    /* Distinct ZIPs plus the Excel manifest */
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

            length filename_only $512
                   remote_file $2048
                   localref $8
                   remoteref $8
                   status $40
                   message $500
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
         * Password authentication is delegated to PuTTY PSFTP because the
         * native SAS SFTP access method on Windows is intended for SSH key
         * authentication. This mode requires XCMD.
         */
        data &out;
            set work._upload_files;

            length filename_only $512
                   remote_file $2048
                   status $40
                   message $500
                   cmd $4096
                   cmdref $8;

            filename_only=scan(local_path,-1,'\/');
            remote_file=cats(prxchange('s/\/+$/','1',strip("&remote_dir")),'/',filename_only);

            /*
             * Run one PSFTP PUT operation per file. The password is passed to
             * PSFTP with -pw; do not use this mode where command-line process
             * arguments are considered sensitive. Prefer AUTH=KEY.
             */
            cmd=cats(
                quote(strip("&psftp")),
                ' -batch -P &port -l ',quote(strip("&user")),
                ' -pw ',quote("&password"),' ',quote(strip("&host")),
                ' -b -'
            );

            cmdref='sftpcmd';
            rc=filename(cmdref,cmd,'PIPE');

            if rc ne 0 then do;
                status='SFTP_ASSIGN_ERROR';
                message=sysmsg();
            end;
            else do;
                /*
                 * PIPE in this form is not suitable for feeding PSFTP batch
                 * input portably across all SAS Windows deployments. For a
                 * production password workflow, use a pre-created PSFTP batch
                 * file or a site-approved credential mechanism.
                 */
                status='PASSWORD_MODE_REQUIRES_SITE_SETUP';
                message='Use AUTH=KEY for native SAS automation, or configure an approved PSFTP batch/credential mechanism with XCMD.';
            end;

            rc2=filename(cmdref);
            output;

            keep local_path remote_file status message;
        run;

    %end;
    %else %do;
        %put ERROR: AUTH must be KEY or PASSWORD.;
        data &out;
            length local_path $1024 remote_file $2048 status $40 message $500;
            local_path='';
            remote_file='';
            status='INVALID_AUTH_MODE';
            message='AUTH must be KEY or PASSWORD.';
            output;
        run;
    %end;

    proc datasets library=work nolist;
        delete _upload_files;
    quit;

%mend sftp_upload_manifest;
