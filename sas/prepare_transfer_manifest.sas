/*
 * prepare_transfer_manifest.sas
 *
 * Excel -> validate each row -> MD5 -> inferred ZIP extraction
 *       -> transfer dataset -> result workbook.
 *
 * The input workbook is read from the current SAS working directory
 * using XLSX_NAME. The result workbook is written to the same directory.
 */

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
               first_member $2048 member_md5 $32 first_md5 $32
               mem_ref $8 extract_ref $8;

        status='OK';
        message='';
        match_count=0;
        first_md5='';
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
                    mem_ref=cats('zm',put(i,z5.));
                    rc2=filename(mem_ref,"%superq(_zip_path)",'ZIP',
                                 cats('member=',quote(strip(member))));

                    if rc2 ne 0 then do;
                        status='ERROR';
                        message=cats('Cannot access ZIP member: ',sysmsg());
                    end;
                    else do;
                        member_md5=hashing_file('MD5',mem_ref,4);

                        if missing(member_md5) then do;
                            status='ERROR';
                            message=cats('ZIP member MD5 calculation failed: ',sysmsg());
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
                    rc2=filename(mem_ref);
                end;
            end;
        end;

        if did>0 then rc2=dclose(did);

        if status='OK' and match_count=0 then do;
            status='ERROR';
            message='Requested file not found in ZIP.';
        end;

        if status='OK' then do;
            md5=first_md5;
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
             transfer_path transfer_name status message;
    run;

    filename inzip clear;
%mend _process_zip_member;

%macro prepare_transfer(
    xlsx_name=,
    sheet=Sheet1,
    out=work.md5_result,
    directory_col=1,
    file_col=4,
    md5_col=6
);
    %local _dircol _filecol _md5col _errors
           _zip_rows _zip_n _z _zip_row _select_list
           _xlsx _result_xlsx _result_name _folder;

    %let _errors=0;

    filename _cwd ".";
    %let _folder=%sysfunc(pathname(_cwd));
    filename _cwd clear;

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

        if missing(directory_path) then do;
            status='ERROR';
            message='DIRECTORY_PATH is required.';
        end;
        else if missing(file_name) then do;
            status='ERROR';
            message='FILE_NAME is required.';
        end;

        if status='OK' and source_type='ZIP' and not whole_zip then do;
            status='ZIP';
        end;
        else if status='OK' then do;
            if whole_zip then transfer_path=directory_path;
            else transfer_path=cats(prxchange('s/[\\\/]+$//',1,directory_path),'\',file_name);

            fileref='srcfile';
            rc=filename(fileref,transfer_path);

            if rc ne 0 then do;
                status='ERROR';
                message=cats('Cannot assign source file: ',sysmsg());
            end;
            else if not fexist(fileref) then do;
                status='ERROR';
                message='Source file does not exist.';
            end;
            else do;
                md5=hashing_file('MD5',fileref,4);
                if missing(md5) then do;
                    status='ERROR';
                    message=cats('MD5 calculation failed: ',sysmsg());
                end;
            end;
            rc=filename(fileref);
        end;

        keep row_id directory_path file_name md5 source_type
             transfer_path transfer_name status message;
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

    data _null_;
        set work._tmp_results end=eof;
        retain errors 0;

        if status='ERROR' then do;
            errors+1;
            putlog 'ERROR: Manifest preparation failed. ' row_id= directory_path=
                   file_name= message=;
        end;

        if eof then call symputx('_errors',errors,'L');
    run;

    %if &_errors>0 %then %do;
        %put ERROR: Transfer manifest preparation failed with &_errors error(s).;
        %goto cleanup;
    %end;

    data &out;
        set work._tmp_results;
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
