/*
 * package_transfer.sas
 *
 * Compress all prepared transfer files into one ZIP and create a CSV
 * containing the final ZIP MD5.
 * An upload_snapshot.sas7bdat dataset records the two final files for SFTP.
 */

%macro package_transfer(
    data=work.md5_result
);
    %local _folder_name _date _study_id _tag_id
           _zip_name _csv_name _zip_path _csv_path _zip_md5 _errors _folder;

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
    %let _errors=0;

    filename _pkgzip "&_zip_path" recfm=n;
    data _null_;
        if fexist('_pkgzip') then rc=fdelete('_pkgzip');
    run;
    filename _pkgzip clear;

    data _null_;
        set &data end=eof;
        length inref outref $8 msg $500;
        retain errors 0;
        inref='pkgin';
        outref='pkgout';
        rc1=filename(inref,transfer_path,'DISK','recfm=n lrecl=1048576');
        rc2=filename(outref,"&_zip_path",'ZIP',
                     cats('member=',quote(strip(relative_path)),
                          ' recfm=n lrecl=1048576'));
        if rc1 ne 0 or rc2 ne 0 then do;
            errors+1; msg=sysmsg();
            putlog 'ERROR: Cannot prepare ZIP member. ' transfer_path= msg=;
        end;
        else if fcopy(inref,outref) ne 0 then do;
            errors+1; msg=sysmsg();
            putlog 'ERROR: Cannot add file to ZIP. ' transfer_path= msg=;
        end;
        rc1=filename(inref);
        rc2=filename(outref);
        if eof then call symputx('_errors',errors,'L');
    run;

    %if &_errors > 0 %then %do;
        %put ERROR: Transfer package creation failed with &_errors error(s).;
        %return;
    %end;

    filename _pkgmd5 "&_zip_path";
    data _null_;
        length zip_md5 $32;
        zip_md5=hashing_file('MD5','_pkgmd5',4);
        call symputx('_zip_md5',zip_md5,'L');
    run;
    filename _pkgmd5 clear;

    %if not %length(%superq(_zip_md5)) %then %do;
        %put ERROR: Cannot calculate MD5 for &_zip_path.;
        %return;
    %end;

    data _null_;
        file "&_csv_path" lrecl=32767;
        put 'file_name,md5';
        put "&_zip_name,&_zip_md5";
    run;

    /* Persist the exact final files that the later SFTP session must upload. */
    libname _uplsnap "&_folder";

    data _uplsnap.upload_snapshot;
        length file_type $8 file_name $1024 file_path $2048;

        file_type='PACKAGE';
        file_name="&_zip_name";
        file_path="&_zip_path";
        output;

        file_type='MD5';
        file_name="&_csv_name";
        file_path="&_csv_path";
        output;
    run;

    libname _uplsnap clear;

%mend package_transfer;
