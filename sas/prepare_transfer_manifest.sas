/*
 * Excel manifest -> validate files -> calculate MD5 -> result Excel.
 */

%macro _process_zip_member(row_id=);
    %local _zip_path;

    data _null_;
        set work._tmp_results(where=(row_id=&row_id));
        call symputx('_zip_path',directory_path);
    run;

    filename inzip ZIP "%superq(_zip_path)";

    data work._tmp_zip_result_&row_id;
        set work._tmp_results(where=(row_id=&row_id));
        length member $2048 member_file $1024 first_member $2048
               member_md5 first_md5 $32 mem_ref extract_ref $8;

        status='OK';
        match_count=0;

        did=dopen('inzip');
        if did=0 then do;
            status='ERROR';
            message=cats('Cannot read ZIP: ',sysmsg());
        end;
        else do i=1 to dnum(did) while(status='OK');
            member=dread(did,i);

            if substr(member,lengthn(member),1) ne '/' then do;
                member_file=scan(member,-1,'/');

                if upcase(strip(member_file))=upcase(strip(transfer_name)) then do;
                    match_count+1;
                    mem_ref=cats('zm',put(i,z5.));
                    rc=filename(mem_ref,"%superq(_zip_path)",'ZIP',
                                cats('member=',quote(strip(member))));

                    if rc ne 0 then do;
                        status='ERROR';
                        message=cats('Cannot access ZIP member: ',sysmsg());
                    end;
                    else do;
                        member_md5=hashing_file('MD5',mem_ref,4);

                        if missing(member_md5) then do;
                            status='ERROR';
                            message='ZIP member MD5 calculation failed.';
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
                    rc=filename(mem_ref);
                end;
            end;
        end;

        if did>0 then rc=dclose(did);

        if status='OK' and match_count=0 then do;
            status='ERROR';
            message='Requested file not found in ZIP.';
        end;

        if status='OK' then do;
            md5=first_md5;
            transfer_path=cats(pathname('work'),'\_extract_',row_id,'_',transfer_name);
            extract_ref='zinmem';

            rc=filename(extract_ref,"%superq(_zip_path)",'ZIP',
                        cats('member=',quote(strip(first_member)),
                             ' recfm=n lrecl=1048576'));
            if rc=0 then
                rc=filename('xout',transfer_path,'DISK','recfm=n lrecl=1048576');

            if rc ne 0 then do;
                status='ERROR';
                message='Cannot prepare ZIP extraction.';
            end;
            else if fcopy(extract_ref,'xout') ne 0 then do;
                status='ERROR';
                message=cats('Extraction failed: ',sysmsg());
            end;

            rc=filename(extract_ref);
            rc=filename('xout');
        end;

        keep row_id directory_path file_name md5 source_type
             transfer_path transfer_name status message;
    run;

    filename inzip clear;
%mend;

%macro prepare_transfer(
    xlsx=,
    sheet=Sheet1,
    result_xlsx=,
    out=work.md5_result,
    directory_col=1,
    file_col=4,
    md5_col=6
);
    %local _dircol _filecol _md5col _errors
           _zip_n _z _zip_row dsid rc;

    %let _zip_n=0;
    %let _errors=0;

    %if not %length(%superq(result_xlsx)) %then
        %let result_xlsx=%sysfunc(prxchange(s/\.xlsx$/_md5_%sysfunc(today(),yymmddn8.).xlsx/i,1,%superq(xlsx)));

    proc import datafile="&xlsx" out=work._tmp_raw dbms=xlsx replace;
        sheet="&sheet";
        getnames=yes;
    run;

    /* Get column names from their Excel positions. */
    %let dsid=%sysfunc(open(work._tmp_raw));
    %if &dsid %then %do;
        %let _dircol=%sysfunc(varname(&dsid,&directory_col));
        %let _filecol=%sysfunc(varname(&dsid,&file_col));
        %let _md5col=%sysfunc(varname(&dsid,&md5_col));
        %let rc=%sysfunc(close(&dsid));
    %end;

    %if not %length(%superq(_dircol)) or
        not %length(%superq(_filecol)) or
        not %length(%superq(_md5col)) %then %do;
        %put ERROR: Requested Excel column does not exist.;
        %goto cleanup;
    %end;

    data work._tmp_input;
        set work._tmp_raw;
        row_id=_n_;
    run;

    /* Column 1 is either a folder path or a ZIP path. */
    data work._tmp_results;
        set work._tmp_input;
        length directory_path $1024 file_name $1024 source_type $3 md5 $32
               transfer_path $2048 transfer_name $1024 status $8 message $500
               fileref $8;

        directory_path=strip(vvaluex("&_dircol"));
        file_name=strip(vvaluex("&_filecol"));
        if missing(directory_path) and missing(file_name) then delete;

        status='OK';
        transfer_name=scan(file_name,-1,'\/');

        if lowcase(scan(strip(directory_path),-1,'.'))='zip' then source_type='ZIP';
        else source_type='DIR';

        whole_zip=(source_type='ZIP' and
                   upcase(strip(transfer_name))=
                   upcase(strip(scan(directory_path,-1,'\/'))));

        if missing(directory_path) then do;
            status='ERROR'; message='DIRECTORY_PATH is required.';
        end;
        else if missing(file_name) then do;
            status='ERROR'; message='FILE_NAME is required.';
        end;
        else if source_type='ZIP' and not whole_zip then status='ZIP';
        else do;
            if whole_zip then transfer_path=directory_path;
            else transfer_path=cats(prxchange('s/[\\\/]+$//',1,directory_path),'\',file_name);

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
                    status='ERROR'; message='MD5 calculation failed.';
                end;
            end;
            rc=filename(fileref);
        end;

        keep row_id directory_path file_name md5 source_type
             transfer_path transfer_name status message;
    run;

    /* Process files stored inside ZIP archives. */
    data _null_;
        set work._tmp_results(where=(status='ZIP')) end=last;
        count+1;
        call symputx(cats('_zip_row',count),row_id,'L');
        if last then call symputx('_zip_n',count);
    run;

    %do _z=1 %to &_zip_n;
        %let _zip_row=&&_zip_row&_z;
        %_process_zip_member(row_id=&_zip_row);
    %end;

    %if &_zip_n>0 %then %do;
        data work._tmp_results;
            set work._tmp_results(where=(status ne 'ZIP')) work._tmp_zip_result_:;
        run;
        proc sort data=work._tmp_results; by row_id; run;
    %end;

    data _null_;
        set work._tmp_results end=last;
        if status='ERROR' then errors+1;
        if last then call symputx('_errors',errors);
    run;

    %if &_errors>0 %then %do;
        data _null_;
            set work._tmp_results;
            if status='ERROR' then
                putlog 'ERROR: ' file_name= message=;
        run;
        %put ERROR: Transfer manifest preparation failed with &_errors error(s).;
        %return;
    %end;

    data &out;
        set work._tmp_results;
        drop status message;
    run;

    /* Put MD5 back into the original Excel data. */
    data work._tmp_output;
        merge work._tmp_input(rename=(&_md5col=_old_md5))
              work._tmp_results(keep=row_id md5);
        by row_id;
        length &_md5col $32;
        &_md5col=md5;
        drop row_id md5 _old_md5;
    run;

    proc export data=work._tmp_output
        outfile="&result_xlsx" dbms=xlsx replace;
        sheet="&sheet";
    run;

%cleanup:
    proc datasets library=work nolist;
        delete _tmp_:;
    quit;
%mend;
