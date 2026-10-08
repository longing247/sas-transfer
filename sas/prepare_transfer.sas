/*
 * prepare_transfer.sas
 *
 * Excel -> validate each row -> inferred ZIP extraction -> certutil MD5
 *       -> transfer dataset -> result workbook.
 *
 * The input workbook is read from the current SAS working directory
 * using XLSX_NAME. The result workbook is written to the same directory.
 */

/* Resolve the directory containing this SAS program. */
data _null_;
    length program_file program_dir $2048;
    length pos 8;

    program_file=dequote(strip(symget('_SASPROGRAMFILE')));

    if missing(program_file) then
        putlog 'ERROR: _SASPROGRAMFILE is empty.';
    else do;
        pos=findc(program_file,'\\/','b');

        if pos>0 then do;
            program_dir=substr(program_file,1,pos-1);
            call symputx('program_dir',strip(program_dir),'G');
        end;
        else putlog 'ERROR: Cannot determine program directory from _SASPROGRAMFILE.';
    end;
run;

%macro _cleanup;
    proc datasets library=work nolist;
        delete _tmp_:;
    quit;
%mend _cleanup;

%macro _resolve__excel_columns(data=, directory_col=, file_col=, md5_col=);
    proc contents data=&data out=work._tmp_cols(keep=name varnum) noprint; run;
    proc sql noprint;
        select name into :_dircol trimmed from work._tmp_cols where varnum=&directory_col;
        select name into :_filecol trimmed from work._tmp_cols where varnum=&file_col;
        select name into :_md5col trimmed from work._tmp_cols where varnum=&md5_col;
    quit;
%mend _resolve__excel_columns;

%macro _process_zip_member(row_id=);
    %local _zip_path;

    proc sql noprint;
        select directory_path
          into :_zip_path trimmed
          from work._tmp_results
         where row_id=&row_id;
    quit;

    filename inzip ZIP "%superq(_zip_path)";

    data work._tmp_zip_result_&row_id;
        set work._tmp_results(where=(row_id=&row_id));

        length member $2048 member_file $1024
               first_member $2048 extract_ref $8;

        status='OK';
        message='';
        match_count=0;
        first_member='';

        did=dopen('inzip');
        putlog 'ZIP_DID=' did;

        if did=0 then do;
            status='ERROR';
            message=cats('Cannot read ZIP: ',sysmsg());
        end;
        else do i=1 to dnum(did) while(status='OK');
            member=dread(did,i);
            putlog 'ZIP_MEMBER=' member;

            if substr(member,lengthn(member),1) ne '/' then do;
                member_file=scan(member,-1,'/');

                if upcase(member_file)=upcase(transfer_name) then do;
                    match_count+1;
                    if match_count=1 then first_member=member;
                end;
            end;
        end;

        if did>0 then rc2=dclose(did);

        if status='OK' and match_count>1 then do;
            status='ERROR';
            message='Duplicate ZIP members match the requested filename.';
        end;

        if status='OK' and match_count=0 then do;
            status='ERROR';
            message='Requested file not found in ZIP.';
        end;

        if status='OK' then do;
            transfer_path=cats(pathname('work'),'\_extract_',row_id,'_',transfer_name);

            extract_ref='zinmem';
            rc1=filename(
                extract_ref,
                "%superq(_zip_path)",
                'ZIP',
                cats('member=',quote(strip(first_member)),
                     ' recfm=n lrecl=1048576')
            );
            rc2=filename('xout',transfer_path,'DISK','recfm=n lrecl=1048576');

            if rc1 ne 0 or rc2 ne 0 then do;
                status='ERROR';
                message=cats('Cannot prepare extraction: ',sysmsg());
            end;
            else if fcopy(extract_ref,'xout') ne 0 then do;
                status='ERROR';
                message=cats('Extraction failed: ',sysmsg());
            end;

            rc1=filename(extract_ref);
            rc2=filename('xout');
        end;

        keep row_id directory_path file_name md5 source_type
             transfer_path transfer_name data_type relative_path status message;
    run;

    filename inzip clear;
%mend _process_zip_member;

%macro prepare_transfer(
    sheet=Sheet1,
    out=work.md5_result,
    directory_col=1,
    file_col=4,
    md5_col=6
);
    %local _dircol _filecol _md5col _errors
           _zip_rows _zip_n _z _zip_row _select_list
           _xlsx _result_xlsx _result_name _folder xlsx_name _hash_rows _hash_n _h _hash_row _hash_path;

    %let _errors=0;
    %let _hash_path=;
    %let _hash_rows=;
    %let _zip_rows=;
    %let xlsx_name=template.xlsx;

    %let _folder=&program_dir;

    %let _xlsx=&_folder.\%superq(xlsx_name);
    %let _result_name=%sysfunc(prxchange(s/\.xlsx$/_md5_%sysfunc(today(),yymmddn8.).xlsx/i,1,%superq(xlsx_name)));
    %let _result_xlsx=&_folder.\&_result_name;

    proc datasets library=work nolist;
        delete md5_result;
    quit;

    options validvarname=any;

    proc import datafile="&_xlsx" out=work._tmp_raw dbms=xlsx replace;
        sheet="&sheet";
        getnames=yes;
    run;

    %_resolve__excel_columns(
        data=work._tmp_raw,
        directory_col=&directory_col,
        file_col=&file_col,
        md5_col=&md5_col
    );

    %if not %length(%superq(_dircol)) or
        not %length(%superq(_filecol)) or
        not %length(%superq(_md5col)) %then %do;
        %put ERROR: One or more requested Excel column indexes do not exist.;
        %goto cleanup;
    %end;

    data work._tmp_input;
        set work._tmp_raw;
        row_id=_n_;
    run;

    data work._tmp_results;
        set work._tmp_input;

        length directory_path $1024 file_name $1024
               source_type $3 md5 $32 transfer_path $2048 transfer_name $1024
               package_name $1024 data_type $1024 relative_path $2048
               status $8 message $500 fileref $8;

        directory_path=strip(vvaluex("&_dircol"));
        file_name=strip(vvaluex("&_filecol"));

        if missing(directory_path) and missing(file_name) then delete;

        status='OK';
        message='';
        transfer_name=scan(file_name,-1,'\/');
        source_type=ifc(prxmatch('/\.zip$/i',strip(directory_path)),'ZIP','DIR');
        whole_zip=(source_type='ZIP' and
                   upcase(transfer_name)=upcase(scan(directory_path,-1,'\/')));

        /*
         * A partially populated manifest row is ignored with a warning.
         * A transfer row is processed only when both column 1 and column 4
         * are populated. Completely blank rows were already deleted above.
         */
        if missing(directory_path) or missing(file_name) then do;
            status='WARNING';
            if missing(directory_path) then
                message='Column 1 (directory path) is missing; row will be skipped.';
            else
                message='Column 4 (file name) is missing; row will be skipped.';
        end;

        if status='OK' then do;
            if index(upcase(directory_path),'INTERIM\\EXPORT') then data_type='RAW_CRF';
            else if index(upcase(directory_path),'INTERIM\\DATA') then data_type='RAW_EXTERNAL';
            else do;
                status='ERROR';
                message='Cannot determine data type from source path.';
            end;
        end;

        if status='OK' then do;
            package_name=transfer_name;

            /* Customize these two strings when a packaged filename must be renamed. */
            if index(upcase(directory_path),upcase('uniqueString')) then
                package_name=prxchange('s/thingsToBeRemoved//i',-1,package_name);

            relative_path=cats(data_type,'/',package_name);
        end;

        if status='OK' and source_type='ZIP' and not whole_zip then do;
            status='ZIP';
        end;
        else if status='OK' then do;
            if whole_zip then transfer_path=directory_path;
            else transfer_path=cats(prxchange('s/[\\\/]+$//',1,directory_path),'\',file_name);

            if not fileexist(transfer_path) then do;
                status='ERROR';
                message='Source file does not exist.';
            end;
            /* MD5 is calculated by PowerShell after the manifest is exported. */
        end;

        keep row_id directory_path file_name md5 source_type
             transfer_path transfer_name data_type relative_path status message whole_zip;
    run;

    proc sql noprint;
        select row_id
          into :_zip_rows separated by ' '
          from work._tmp_results
         where status='ZIP';
    quit;

    %let _zip_n=%sysfunc(countw(%superq(_zip_rows),%str( )));

    %if &_zip_n>0 %then %do;
        %do _z=1 %to &_zip_n;
            %let _zip_row=%scan(%superq(_zip_rows),&_z,%str( ));
            %_process_zip_member(row_id=&_zip_row);
        %end;

        data work._tmp_results;
            set work._tmp_results(where=(status ne 'ZIP'))
                work._tmp_zip_result_:;
        run;

        proc sort data=work._tmp_results;
            by row_id;
        run;
    %end;

    /* Direct Windows certutil MD5 for each prepared physical file. */
    proc sql noprint;
        select row_id into :_hash_rows separated by ' '
        from work._tmp_results where status='OK';
    quit;

    %let _hash_n=%sysfunc(countw(%superq(_hash_rows),%str( )));
    %do _h=1 %to &_hash_n;
        %let _hash_row=%scan(%superq(_hash_rows),&_h,%str( ));

        data _null_;
            set work._tmp_results(where=(row_id=&_hash_row));
            call symputx('_hash_path',strip(transfer_path),'L');
        run;

        /* PIPE reads certutil output directly; no temporary MD5 file. */
        filename win_cmd pipe "certutil.exe -hashfile ""&_hash_path"" MD5";

        data work._tmp_hash_one;
            length calculated_md5 $32 hash_status $8 hash_message $500
                   line $512 candidate $512;
            row_id=&_hash_row;
            hash_status='OK';
            hash_message='';
            matches=0;
            infile win_cmd truncover end=eof;
            do until(eof);
                input line $char512.;
                candidate=compress(strip(line),' ');
                if prxmatch('/^[0-9A-F]{32}$/i',strip(candidate)) then do;
                    matches+1;
                    calculated_md5=upcase(candidate);
                end;
            end;
            if matches ne 1 then do;
                hash_status='ERROR';
                hash_message='certutil did not return exactly one valid MD5.';
                calculated_md5='';
            end;
            output;
            keep row_id calculated_md5 hash_status hash_message;
        run;
        filename win_cmd clear;

        %if &_h=1 %then %do;
            data work._tmp_hash_results;
                set work._tmp_hash_one;
            run;
        %end;
        %else %do;
            proc append base=work._tmp_hash_results data=work._tmp_hash_one force; run;
        %end;
    %end;

    %if &_hash_n=0 %then %do;
        %put ERROR: No valid transfer files found in manifest.;
        %goto cleanup;
    %end;

    %if &_hash_n>0 %then %do;
        proc sort data=work._tmp_results; by row_id; run;
        proc sort data=work._tmp_hash_results; by row_id; run;
        data work._tmp_results;
            merge work._tmp_results(in=original)
                  work._tmp_hash_results(in=hashed);
            by row_id;
            if original;
            if status='OK' then do;
                if not hashed then do;
                    status='ERROR';
                    message='No MD5 result returned for manifest row.';
                end;
                else do;
                    md5=calculated_md5;
                    status=hash_status;
                    message=hash_message;
                end;
            end;
            drop calculated_md5 hash_status hash_message;
        run;
    %end;

    data _null_;
        set work._tmp_results end=eof;
        retain errors 0;

        if status='ERROR' then do;
            errors+1;
            putlog 'ERROR: Manifest preparation failed. ' row_id= directory_path=
                   file_name= message=;
        end;
        else if status='WARNING' then
            putlog 'WARNING: Manifest row skipped. ' row_id= directory_path=
                   file_name= message=;

        if eof then call symputx('_errors',errors,'L');
    run;

    %if &_errors>0 %then %do;
        %put ERROR: Transfer manifest preparation failed with &_errors error(s).;
        %goto cleanup;
    %end;

    data &out;
        set work._tmp_results(where=(status='OK'));
        drop status message;
    run;

    proc sql noprint;
        select case
                 when varnum=&md5_col then
                     cats('b.md5 as ',nliteral(name))
                 else
                     cats('a.',nliteral(name))
               end
          into :_select_list separated by ', '
          from work._tmp_cols
         order by varnum;
    quit;

    proc sql;
        create table work._tmp_output as
        select &_select_list
          from work._tmp_input as a
          left join work._tmp_results as b
            on a.row_id=b.row_id
         order by a.row_id;
    quit;

    proc export data=work._tmp_output
        outfile="&_result_xlsx"
        dbms=xlsx
        replace;
        sheet="&sheet";
    run;

    %if &syserr>4 %then %do;
        %put ERROR: Could not create result workbook: &_result_xlsx;
    %end;

%cleanup:
    %_cleanup;

%mend prepare_transfer;


/* Package the prepared files and create the persistent upload snapshot. */
%macro package_transfer(data=work.md5_result);
    %local _folder_name _date _study_id _tag_id
           _zip_name _csv_name _zip_path _csv_path _zip_md5 _errors _folder;

    %if not %sysfunc(exist(&data)) %then %do;
        %put ERROR: Prepared transfer dataset &data does not exist; packaging skipped.;
        %return;
    %end;

    %let _folder=&program_dir;
    %let _folder_name=%sysfunc(scan(%superq(_folder),-1,%str(\/)));
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
    %let _pkg_ps_rc=1;

    filename _pkgzip "&_zip_path" recfm=n;
    data _null_;
        if fexist('_pkgzip') then rc=fdelete('_pkgzip');
    run;
    %if %sysfunc(fileref(_pkgzip))=0 %then %do;
        filename _pkgzip clear;
    %end;

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

    %let _zip_md5=;
    filename pkg_cmd pipe "certutil.exe -hashfile ""&_zip_path"" MD5";

    data _null_;
        length line $512 candidate $512 value $32;
        retain matches 0;
        infile pkg_cmd truncover end=eof;
        do until(eof);
            input line $char512.;
            candidate=compress(strip(line),' ');
            if prxmatch('/^[0-9A-F]{32}$/i',strip(candidate)) then do;
                matches+1;
                value=upcase(candidate);
            end;
        end;
        if matches=1 then call symputx('_zip_md5',value,'L');
    run;
    filename pkg_cmd clear;

    %if not %length(%superq(_zip_md5)) %then %do;
        %put ERROR: Cannot calculate MD5 for &_zip_path.;
        %return;
    %end;

    data _null_;
        file "&_csv_path" lrecl=32767;
        put 'file_name,md5';
        put "&_zip_name,&_zip_md5";
    run;

    libname _uplsnap "&_folder";
    data _uplsnap.upload_snapshot;
        length file_type $8 file_name $1024 file_path $2048;
        file_type='PACKAGE'; file_name="&_zip_name"; file_path="&_zip_path"; output;
        file_type='MD5'; file_name="&_csv_name"; file_path="&_csv_path"; output;
    run;
    libname _uplsnap clear;

    /*
     * Persist the prepared per-file result for later validation tests.
     * This keeps the source paths, calculated MD5 values and package paths.
     */
    libname _testout "&_folder";
    data _testout.prepare_transfer_result;
        set &data;
    run;
    libname _testout clear;
%mend package_transfer;


/* Run preparation and packaging as one transfer preparation program. */
proc printto log="&program_dir.\prepare_transfer.log" new;
run;

%put NOTE: ===== PREPARE TRANSFER STARTED =====;
%prepare_transfer;
%put NOTE: ===== PREPARE TRANSFER FINISHED =====;

%put NOTE: ===== PACKAGE TRANSFER STARTED =====;
%package_transfer;
%put NOTE: ===== PACKAGE TRANSFER FINISHED =====;

proc printto;
run;
