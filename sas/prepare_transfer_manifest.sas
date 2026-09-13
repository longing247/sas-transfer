/*
 * prepare_transfer_manifest.sas
 *
 * Row-based manifest processing:
 *   Excel -> validate each row -> MD5 -> inferred ZIP extraction
 *         -> SFTP-ready dataset -> formatted result workbook.
 *
 * The result workbook is a copy of the input workbook. SAS then updates only
 * the configured MD5 cells through LIBNAME EXCEL so formatting is preserved.
 */

%macro _pm_cleanup;
    proc datasets library=work nolist;
        delete _pm_:;
    quit;
%mend _pm_cleanup;

%macro _pm_resolve_columns(data=, directory_col=, file_col=, md5_col=, sftp_target_col=);
    proc contents data=&data out=work._pm_cols(keep=name varnum) noprint; run;
    proc sql noprint;
        select name into :_dircol trimmed from work._pm_cols where varnum=&directory_col;
        select name into :_filecol trimmed from work._pm_cols where varnum=&file_col;
        select name into :_md5col trimmed from work._pm_cols where varnum=&md5_col;
        select name into :_sftpcol trimmed from work._pm_cols where varnum=&sftp_target_col;
    quit;
%mend _pm_resolve_columns;

%macro prepare_transfer_manifest(
    xlsx=,
    sheet=Sheet1,
    result_xlsx=,
    out=work.md5_result,
    directory_col=1,
    file_col=4,
    md5_col=6,
    sftp_target_col=7
);
    %local _dircol _filecol _md5col _sftpcol _errors _copy_error
           _xldirref _xlfileref _xlmd5ref _xlmd5type;

    /* Remove the previous successful result. */
    proc datasets library=work nolist;
        delete md5_result;
    quit;

    proc import datafile="&xlsx" out=work._pm_raw dbms=xlsx replace;
        sheet="&sheet";
        getnames=yes;
    run;

    %_pm_resolve_columns(
        data=work._pm_raw,
        directory_col=&directory_col,
        file_col=&file_col,
        md5_col=&md5_col,
        sftp_target_col=&sftp_target_col
    );

    %if not %length(%superq(_dircol)) or
        not %length(%superq(_filecol)) or
        not %length(%superq(_md5col)) or
        not %length(%superq(_sftpcol)) %then %do;
        %put ERROR: One or more requested Excel column indexes do not exist.;
        %goto cleanup;
    %end;

    data work._pm_input;
        set work._pm_raw;
        row_id=_n_;
    run;

    data work._pm_results;
        set work._pm_input;

        length directory_path $1024 file_name $1024 sftp_target $2048
               source_type $3 md5 $32 transfer_path $2048 transfer_name $1024
               status $8 message $500 member $2048 member_file $1024
               first_member $2048 member_md5 $32 first_md5 $32
               zipref memref outref fileref $8;

        directory_path=strip(vvaluex("&_dircol"));
        file_name=strip(vvaluex("&_filecol"));
        sftp_target=strip(vvaluex("&_sftpcol"));

        if missing(directory_path) and missing(file_name) then delete;

        status='OK';
        message='';
        transfer_name=scan(file_name,-1,'\\/');
        source_type=ifc(prxmatch('/\.zip$/i',directory_path),'ZIP','DIR');
        whole_zip=(source_type='ZIP' and
                   upcase(transfer_name)=upcase(scan(directory_path,-1,'\\/')));

        if missing(directory_path) then do;
            status='ERROR'; message='DIRECTORY_PATH is required.';
        end;
        else if missing(file_name) then do;
            status='ERROR'; message='FILE_NAME is required.';
        end;
        else if missing(sftp_target) then do;
            status='ERROR'; message='SFTP_TARGET is required.';
        end;

        if status='OK' and (source_type='DIR' or whole_zip) then do;
            if whole_zip then transfer_path=directory_path;
            else transfer_path=cats(prxchange('s/[\\\\\/]+$//',1,directory_path),'\',file_name);

            fileref='srcfile';
            rc=filename(fileref,transfer_path);
            if rc ne 0 then do;
                status='ERROR'; message=cats('Cannot assign source file: ',sysmsg());
            end;
            else if not fexist(fileref) then do;
                status='ERROR'; message='Source file does not exist.';
            end;
            else do;
                md5=hashing_file('MD5',fileref,4);
                if missing(md5) then do;
                    status='ERROR'; message=cats('MD5 calculation failed: ',sysmsg());
                end;
            end;
            rc=filename(fileref);
        end;

        if status='OK' and source_type='ZIP' and not whole_zip then do;
            match_count=0;
            first_md5='';
            first_member='';
            zipref='inzip';
            rc=filename(zipref,directory_path,'ZIP');

            if rc ne 0 then do;
                status='ERROR'; message=cats('Cannot open ZIP: ',sysmsg());
            end;
            else do;
                did=dopen(zipref);
                if did=0 then do;
                    status='ERROR'; message=cats('Cannot read ZIP: ',sysmsg());
                end;
                else do i=1 to dnum(did) while(status='OK');
                    member=dread(did,i);
                    if substr(member,lengthn(member),1) ne '/' then do;
                        member_file=scan(member,-1,'/');
                        if upcase(member_file)=upcase(transfer_name) then do;
                            match_count+1;
                            memref='zipmem';
                            rc2=filename(memref,directory_path,'ZIP',
                                         cats('member=',quote(strip(member))));
                            if rc2 ne 0 then do;
                                status='ERROR'; message='Cannot access ZIP member.';
                            end;
                            else do;
                                member_md5=hashing_file('MD5',memref,4);
                                if missing(member_md5) then do;
                                    status='ERROR'; message='ZIP member MD5 calculation failed.';
                                end;
                                else if match_count=1 then do;
                                    first_md5=member_md5;
                                    first_member=member;
                                end;
                                else if member_md5 ne first_md5 then do;
                                    status='ERROR';
                                    message='Duplicate ZIP members have different MD5 values.';
                                end;
                            end;
                            rc2=filename(memref);
                        end;
                    end;
                end;
                rc2=dclose(did);
            end;
            rc=filename(zipref);

            if status='OK' and match_count=0 then do;
                status='ERROR'; message='Requested file not found in ZIP.';
            end;

            if status='OK' then do;
                md5=first_md5;
                transfer_path=cats(pathname('work'),'\_extract_',row_id,'_',transfer_name);
                memref='zinmem'; outref='xout';
                rc1=filename(memref,directory_path,'ZIP',
                             cats('member=',quote(strip(first_member))));
                rc2=filename(outref,transfer_path,'DISK','recfm=n');
                if rc1 ne 0 or rc2 ne 0 then do;
                    status='ERROR'; message=cats('Cannot prepare extraction: ',sysmsg());
                end;
                else if fcopy(memref,outref) ne 0 then do;
                    status='ERROR'; message=cats('Extraction failed: ',sysmsg());
                end;
                rc1=filename(memref);
                rc2=filename(outref);
            end;
        end;

        keep row_id directory_path file_name md5 sftp_target source_type
             transfer_path transfer_name status message;
    run;

    data _null_;
        set work._pm_results end=eof;
        retain errors 0;
        if status='ERROR' then do;
            errors+1;
            putlog 'ERROR: Manifest preparation failed. ' row_id= directory_path=
                   file_name= message=;
        end;
        if eof then call symputx('_errors',errors,'L');
    run;

    %if %sysevalf(%superq(_errors)=,boolean) %then %let _errors=0;
    %if &_errors>0 %then %do;
        %put ERROR: Transfer manifest preparation failed with &_errors error(s).;
        %goto cleanup;
    %end;

    data &out;
        set work._pm_results;
        drop status message;
    run;

    /* Copy the original workbook, then update only its MD5 cells. */
    %let _copy_error=0;
    filename _pmsrc "&xlsx" recfm=n;
    filename _pmdst "&result_xlsx" recfm=n;

    data _null_;
        length msg $500;
        if fexist('_pmdst') then rc=fdelete('_pmdst');
        rc=fcopy('_pmsrc','_pmdst');
        if rc ne 0 then do;
            msg=sysmsg();
            putlog 'ERROR: Cannot copy result workbook. ' msg=;
            call symputx('_copy_error',1,'L');
        end;
    run;

    filename _pmsrc clear;
    filename _pmdst clear;

    %if &_copy_error %then %goto cleanup;

    libname _pmxl excel path="&result_xlsx" scantext=no filelock=yes;

    %if %sysfunc(libref(_pmxl)) ne 0 %then %do;
        %put ERROR: Cannot open the copied workbook with the EXCEL LIBNAME engine.;
        %goto delete_result;
    %end;

    proc contents data=_pmxl."&sheet.$"n
        out=work._pm_xlcols(keep=name varnum type) noprint;
    run;

    %let _xldirref=;
    %let _xlfileref=;
    %let _xlmd5ref=;
    %let _xlmd5type=;

    data _null_;
        set work._pm_xlcols;
        if varnum=&directory_col then call symputx('_xldirref',nliteral(name),'L');
        if varnum=&file_col then call symputx('_xlfileref',nliteral(name),'L');
        if varnum=&md5_col then do;
            call symputx('_xlmd5ref',nliteral(name),'L');
            call symputx('_xlmd5type',type,'L');
        end;
    run;

    %if not %length(%superq(_xldirref)) or
        not %length(%superq(_xlfileref)) or
        not %length(%superq(_xlmd5ref)) %then %do;
        libname _pmxl clear;
        %goto delete_result;
    %end;

    %if %superq(_xlmd5type) ne 2 %then %do;
        %put ERROR: Format the Excel MD5 column as Text and retry.;
        libname _pmxl clear;
        %goto delete_result;
    %end;

    filename _pmsql temp;
    data _null_;
        set work._pm_results end=eof;
        file _pmsql lrecl=32767;
        length qdir qfile qmd5 $4096 sql_line $32767;

        qdir=tranwrd(strip(directory_path),"'","''");
        qfile=tranwrd(strip(file_name),"'","''");
        qmd5=tranwrd(strip(md5),"'","''");

        if _n_=1 then put 'proc sql;';
        sql_line=cats(
            'update _pmxl."', "&sheet", '$"n set ', "&_xlmd5ref", "='", qmd5,
            "' where ", "&_xldirref", "='", qdir,
            "' and ", "&_xlfileref", "='", qfile, "';"
        );
        put sql_line;
        if eof then put 'quit;';
    run;

    %include _pmsql;
    filename _pmsql clear;
    libname _pmxl clear;

    %if &sqlrc ne 0 %then %goto delete_result;
    %goto cleanup;

%delete_result:
    filename _pmdel "&result_xlsx" recfm=n;
    data _null_;
        if fexist('_pmdel') then rc=fdelete('_pmdel');
    run;
    filename _pmdel clear;

%cleanup:
    %_pm_cleanup;
%mend prepare_transfer_manifest;
