/*
 * package_transfer.sas
 *
 * Compress all prepared transfer files into one ZIP and create a CSV
 * containing the ZIP MD5 first, followed by each transfer file MD5.
 * Both files are written to the current SAS working directory.
 */

%macro package_transfer(
    data=work.md5_result,
    study_id=,
    tag_id=
);
    %local _date _zip_name _csv_name _zip_path _csv_path _zip_md5 _errors _folder;

    %let _folder=&program_dir;

    %let _date=%sysfunc(today(),yymmddn8.);
    %let _zip_name=&_date._&study_id._&tag_id..zip;
    %let _csv_name=&_date._&study_id._&tag_id._md5.csv;
    %let _zip_path=&_folder.\&_zip_name;
    %let _csv_path=&_folder.\&_csv_name;
    %let _errors=0;

    /* Remove an existing package with the same name. */
    filename _pkgzip "&_zip_path" recfm=n;
    data _null_;
        if fexist('_pkgzip') then rc=fdelete('_pkgzip');
    run;
    filename _pkgzip clear;

    /* Add every prepared transfer file to the ZIP. */
    data _null_;
        set &data end=eof;
        length inref outref $8 msg $500;
        retain errors 0;

        inref='pkgin';
        outref='pkgout';

        rc1=filename(inref,transfer_path,'DISK','recfm=n');
        rc2=filename(outref,"&_zip_path",'ZIP',
                     cats('member=',quote(strip(relative_path))));

        if rc1 ne 0 or rc2 ne 0 then do;
            errors+1;
            msg=sysmsg();
            putlog 'ERROR: Cannot prepare ZIP member. ' transfer_path= msg=;
        end;
        else if fcopy(inref,outref) ne 0 then do;
            errors+1;
            msg=sysmsg();
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

    /* Compute MD5 of the completed ZIP. */
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

    /* ZIP checksum first, then all individual file checksums. */
    data _null_;
        file "&_csv_path" lrecl=32767;

        put 'file_name,md5';
        put "&_zip_name,&_zip_md5";

        do until(eof);
            set &data(keep=relative_path md5) end=eof;
            put relative_path ',' md5;
        end;

        stop;
    run;

%mend package_transfer;
