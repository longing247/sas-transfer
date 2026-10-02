/*
 * sftp_upload_manifest.sas
 *
 * Uploads the final transfer package ZIP and its MD5 summary CSV.
 *
 * The files are derived from PROGRAM_DIR, so this macro can run in a
 * separate SAS session after the preparation/package session has ended.
 *
 * A remote upload directory named after the PROGRAM_DIR folder is created
 * under REMOTE_DIR for each upload.
 */

%macro sftp_upload_manifest(
    host=,
    user=,
    remote_dir=,
    keyfile=,
    port=22,
    out=work.sftp_upload_log
);
    %local _folder _folder_name _date _study_id _tag_id
           _zip_name _csv_name _zip_path _csv_path _remote_upload_dir;

    %let _folder=&program_dir;
    %let _folder_name=%sysfunc(scan(%superq(_folder),-1,%str(\/)));

    /* Parse folder name: YYYYMMDD_STUDYID_TAGID. */
    %let _date=%scan(%superq(_folder_name),1,_);
    %let _study_id=%scan(%superq(_folder_name),2,_);
    %let _tag_id=%scan(%superq(_folder_name),3,_);

    %if not %sysfunc(prxmatch(%str(/^\d{8}_[^_]+_[^_]+$/),%superq(_folder_name))) %then %do;
        %put ERROR: Program folder must follow YYYYMMDD_STUDYID_TAGID: &_folder_name;
        %return;
    %end;

    %let _zip_name=&_date._&_study_id._&_tag_id..zip;
    %let _csv_name=&_date._&_study_id._&_tag_id._md5.csv;
    %let _zip_path=&_folder.\&_zip_name;
    %let _csv_path=&_folder.\&_csv_name;
    %let _remote_upload_dir=%sysfunc(prxchange(s/\/+$/,,%superq(remote_dir)))/&_folder_name;

    /* Create REMOTE_DIR/YYYYMMDD_STUDYID_TAGID before uploading files. */
    filename sftppar SFTP "%superq(remote_dir)"
        host="&host"
        user="&user"
        optionsx="-P &port -i %sysfunc(quote(%superq(keyfile)))";

    data _null_;
        length message $500;
        did=dopen('sftppar');

        if did>0 then do;
            rc=dcreate("&_folder_name",'sftppar');

            if rc=0 then do;
                message=sysmsg();
                putlog 'NOTE: Remote upload directory already exists or could not be created: '
                       "&_remote_upload_dir" '. ' message;
            end;
            else
                putlog "NOTE: Remote upload directory created: &_remote_upload_dir";

            rc_close=dclose(did);
        end;
        else do;
            message=sysmsg();
            putlog 'ERROR: Remote parent directory could not be opened. ' message;
        end;
    run;

    filename sftppar clear;

    /* Build the two persistent files produced by PACKAGE_TRANSFER. */
    data work._upload_files;
        length local_path $2048 transfer_name $1024;

        local_path="&_zip_path";
        transfer_name="&_zip_name";
        output;

        local_path="&_csv_path";
        transfer_name="&_csv_name";
        output;
    run;

    /* Native SAS SFTP filename engine, key authentication. */
    data &out;
        set work._upload_files;
        length remote_file $2048 localref $8 remoteref $8
               status $40 message $500 sftp_options $2048;
        format upload_dttm e8601dt19.;

        upload_dttm=datetime();
        remote_file=cats("&_remote_upload_dir",'/',strip(transfer_name));

        localref='localf';
        remoteref='remotef';

        rc_local=filename(localref,local_path,'DISK','recfm=n lrecl=1048576');

        if rc_local ne 0 or fexist(localref)=0 then do;
            status='LOCAL_FILE_ERROR';
            message=sysmsg();
            output;
            rc_clear=filename(localref);
            return;
        end;

        sftp_options=cats('-P &port -i ',quote(strip("&keyfile")));
        rc_remote=filename(
            remoteref,
            remote_file,
            'SFTP',
            cats(
                'host=',quote("&host"),' ',
                'user=',quote("&user"),' ',
                'recfm=n ',
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

        keep local_path remote_file upload_dttm status message;
    run;

    proc datasets library=work nolist;
        delete _upload_files;
    quit;
%mend sftp_upload_manifest;
