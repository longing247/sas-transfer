/*
 * sftp_upload_manifest.sas
 *
 * Uploads the resolved TRANSFER_PATH produced by %source_md5().
 * Each run receives a BATCH_ID. Files are uploaded beneath:
 *
 *     <SFTP_TARGET>/<BATCH_ID>/<TRANSFER_NAME>
 *
 * REMOTE_DIR is the fallback base target and is also used for the result Excel
 * file when EXCEL= is supplied.
 *
 * BATCH_ID defaults to YYYYMMDD_HHMMSS, for example 20260913_001530.
 * Supply BATCH_ID= explicitly when a scheduler or upstream process owns the
 * batch identifier.
 *
 * Important: the remote batch directory must already exist on the SFTP server.
 * The native SAS SFTP filename-engine path used by AUTH=KEY does not create
 * remote directories in this macro.
 *
 * Windows/SAS notes:
 * - AUTH=KEY uses the native SAS SFTP filename engine and a PuTTY .ppk key.
 * - AUTH=PASSWORD uses PuTTY psftp.exe and requires XCMD permission.
 */

%macro sftp_upload_manifest(
    data=,
    excel=,
    host=,
    user=,
    remote_dir=,
    batch_id=,
    auth=KEY,
    keyfile=,
    passphrase=,
    password=,
    psftp=psftp.exe,
    port=22,
    out=work.sftp_upload_log
);
    %local _auth _batch_id;
    %let _auth=%upcase(%superq(auth));

    %if %length(%superq(batch_id)) %then %do;
        %let _batch_id=%superq(batch_id);
    %end;
    %else %do;
        %let _batch_id=%sysfunc(date(),yymmddn8.)_%sysfunc(time(),hhmmss6.);
    %end;

    %put NOTE: SFTP batch ID=&_batch_id;

    proc sort data=&data(
        keep=transfer_path transfer_name sftp_target
        where=(not missing(transfer_path))
    ) out=work._upload_files nodupkey;
        by transfer_path transfer_name sftp_target;
    run;

    data work._upload_files;
        set work._upload_files end=eof;
        length local_path $2048 base_target $2048 target_dir $2048 batch_id $64;
        batch_id="&_batch_id";
        local_path=transfer_path;
        base_target=coalescec(strip(sftp_target),strip("&remote_dir"));

        if not missing(base_target) then
            target_dir=cats(prxchange('s/\/+$/','1',strip(base_target)),'/',batch_id);
        output;

        %if %length(%superq(excel)) %then %do;
            if eof then do;
                local_path="&excel";
                transfer_name=scan(local_path,-1,'\\/');
                base_target=strip("&remote_dir");
                if not missing(base_target) then
                    target_dir=cats(prxchange('s/\/+$/','1',strip(base_target)),'/',batch_id);
                else call missing(target_dir);
                output;
            end;
        %end;

        keep local_path transfer_name base_target target_dir batch_id;
    run;

    %if &_auth = KEY %then %do;
        data &out;
            set work._upload_files;
            length remote_file $2048 localref $8 remoteref $8
                   status $40 message $500 sftp_options $2048;
            format upload_dttm e8601dt19.;
            upload_dttm=datetime();

            if missing(target_dir) then do;
                status='SFTP_TARGET_ERROR';
                message='SFTP base target directory is missing.';
                output;
                return;
            end;

            remote_file=cats(prxchange('s/\/+$/','1',strip(target_dir)),'/',strip(transfer_name));
            localref='localf';
            remoteref='remotef';

            rc_local=filename(localref,local_path);
            if rc_local ne 0 or fexist(localref)=0 then do;
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

            rc_remote=filename(remoteref,remote_file,'SFTP',cats(
                'host=',quote("&host"),' ','user=',quote("&user"),' ',
                'recfm=s ','optionsx=',quote(trim(sftp_options))));

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
            keep batch_id local_path remote_file upload_dttm status message;
        run;
    %end;
    %else %if &_auth = PASSWORD %then %do;
        filename _sftpbatch temp;

        data &out;
            set work._upload_files;
            length remote_file $2048 status $40 message $500
                   batch_path $1024 cmd $4096 batch_line $4096;
            format upload_dttm e8601dt19.;
            upload_dttm=datetime();

            if missing(target_dir) then do;
                status='SFTP_TARGET_ERROR';
                message='SFTP base target directory is missing.';
                output;
                return;
            end;

            remote_file=cats(prxchange('s/\/+$/','1',strip(target_dir)),'/',strip(transfer_name));
            batch_path=pathname('_sftpbatch');
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

            cmd=cats(quote(strip("&psftp")),' -batch -P &port',
                     ' -l ',quote(strip("&user")),' -pw ',quote("&password"),
                     ' -b ',quote(strip(batch_path)),' ',quote(strip("&host")));
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
            keep batch_id local_path remote_file upload_dttm status message;
        run;

        filename _sftpbatch clear;
    %end;
    %else %do;
        %put ERROR: AUTH must be KEY or PASSWORD.;
    %end;

    proc datasets library=work nolist;
        delete _upload_files;
    quit;
%mend sftp_upload_manifest;
