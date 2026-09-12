/*
 * sftp_upload_manifest.sas
 *
 * Uploads TRANSFER_PATH values produced by %prepare_transfer_manifest().
 *
 * Production assumptions are intentionally simple:
 * - key authentication only;
 * - every manifest row has SFTP_TARGET;
 * - BATCH_ID is supplied by the caller;
 * - REMOTE_DIR is used only for the completed Excel manifest.
 *
 * Remote batch directories must already exist.
 */

%macro sftp_upload_manifest(
    data=,
    excel=,
    host=,
    user=,
    remote_dir=,
    batch_id=,
    keyfile=,
    passphrase=,
    port=22,
    out=work.sftp_upload_log
);
    %if not %length(%superq(batch_id)) %then %do;
        %put ERROR: BATCH_ID is required.;
        %return;
    %end;

    /* One upload row per unique resolved local file. */
    proc sort data=&data(
        keep=transfer_path transfer_name sftp_target
        where=(not missing(transfer_path))
    ) out=work._upload_files nodupkey;
        by transfer_path transfer_name sftp_target;
    run;

    data work._upload_files;
        set work._upload_files end=eof;
        length local_path $2048 target_dir $2048 batch_id $64;

        batch_id="&batch_id";
        local_path=transfer_path;
        target_dir=cats(prxchange('s/\/+$/','1',strip(sftp_target)),'/',batch_id);
        output;

        /* Upload the completed manifest to REMOTE_DIR/BATCH_ID. */
        %if %length(%superq(excel)) %then %do;
            if eof then do;
                local_path="&excel";
                transfer_name=scan(local_path,-1,'\\/');
                target_dir=cats(prxchange('s/\/+$/','1',strip("&remote_dir")),'/',batch_id);
                output;
            end;
        %end;

        keep local_path transfer_name target_dir batch_id;
    run;

    /* Native SAS SFTP filename engine, key authentication only. */
    data &out;
        set work._upload_files;
        length remote_file $2048 localref $8 remoteref $8
               status $40 message $500 sftp_options $2048;
        format upload_dttm e8601dt19.;
        upload_dttm=datetime();

        if missing(target_dir) then do;
            status='SFTP_TARGET_ERROR';
            message='SFTP target directory is missing.';
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

    proc datasets library=work nolist;
        delete _upload_files;
    quit;
%mend sftp_upload_manifest;
