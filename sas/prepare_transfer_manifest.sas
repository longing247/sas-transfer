/*
 * prepare_transfer_manifest.sas
 *
 * Row-based manifest processing:
 *   Excel -> validate each row -> MD5 -> optional ZIP extraction
 *         -> SFTP-ready dataset -> completed result workbook.
 *
 * The manifest columns are selected by position. MD5 is output only.
 * HASHING_FILE() requires SAS 9.4M6+.
 */

%macro _pm_resolve_columns(data=, directory_col=, file_col=, sftp_target_col=, extract_col=);
    proc contents data=&data out=work._pm_cols(keep=name varnum) noprint; run;
    proc sql noprint;
        select name into :_dircol trimmed from work._pm_cols where varnum=&directory_col;
        select name into :_filecol trimmed from work._pm_cols where varnum=&file_col;
        select name into :_sftpcol trimmed from work._pm_cols where varnum=&sftp_target_col;
        select name into :_extractcol trimmed from work._pm_cols where varnum=&extract_col;
    quit;
%mend _pm_resolve_columns;

%macro prepare_transfer_manifest(
    xlsx=,
    sheet=Sheet1,
    result_xlsx=,
    out=work.md5_result,
    directory_col=1,
    file_col=2,
    sftp_target_col=4,
    extract_col=5
);
    %local _dircol _filecol _sftpcol _extractcol _errors _outlib _outmem;

    /* Never leave a previous successful result after a failed run. */
    %let _outlib=%scan(&out,1,.);
    %let _outmem=%scan(&out,2,.);
    %if %length(&_outmem)=0 %then %do;
        %let _outmem=&_outlib;
        %let _outlib=WORK;
    %end;
    %if %sysfunc(exist(&out)) %then %do;
        proc datasets library=&_outlib nolist; delete &_outmem; quit;
    %end;

    proc import datafile="&xlsx" out=work._pm_raw dbms=xlsx replace;
        sheet="&sheet";
        getnames=yes;
    run;

    %_pm_resolve_columns(
        data=work._pm_raw,
        directory_col=&directory_col,
        file_col=&file_col,
        sftp_target_col=&sftp_target_col,
        extract_col=&extract_col
    );

    %if not %length(%superq(_dircol)) or
        not %length(%superq(_filecol)) or
        not %length(%superq(_sftpcol)) or
        not %length(%superq(_extractcol)) %then %do;
        %put ERROR: One or more requested Excel column indexes do not exist.;
        %goto cleanup;
    %end;

    /*
     * Process one manifest row at a time. ZIPs may therefore be opened more
     * than once, which is intentional: the simpler control flow is preferred
     * for transfer manifests of ordinary size.
     */
    data work._pm_results;
        set work._pm_raw;

        length directory_path $1024 file_name $1024 sftp_target $2048
               extract $1 source_type $3 md5 $32
               transfer_path $2048 transfer_name $1024
               status $8 message $500
               member $2048 member_file $1024 first_member $2048
               member_md5 $32 first_md5 $32
               zipref memref outref fileref $8;

        row_id=_n_;
        directory_path=strip(vvaluex("&_dircol"));
        file_name=strip(vvaluex("&_filecol"));
        sftp_target=strip(vvaluex("&_sftpcol"));
        extract=upcase(substr(strip(vvaluex("&_extractcol")),1,1));

        if missing(directory_path) and missing(file_name) then delete;

        status='OK';
        message='';
        transfer_name=scan(file_name,-1,'\/');
        source_type=ifc(prxmatch('/\.zip$/i',directory_path),'ZIP','DIR');

        /* Validate the row before touching the source. */
        if missing(directory_path) then do;
            status='ERROR'; message='DIRECTORY_PATH is required.';
        end;
        else if missing(file_name) then do;
            status='ERROR'; message='FILE_NAME is required.';
        end;
        else if missing(sftp_target) then do;
            status='ERROR'; message='SFTP_TARGET is required.';
        end;
        else if extract not in ('Y','N') then do;
            status='ERROR'; message='EXTRACT must be Y or N.';
        end;
        else if source_type='DIR' and extract='Y' then do;
            status='ERROR'; message='EXTRACT must be N when DIRECTORY_PATH is a directory.';
        end;
        else if source_type='ZIP' and extract='N' and
                upcase(transfer_name) ne upcase(scan(directory_path,-1,'\/')) then do;
            status='ERROR'; message='For ZIP + EXTRACT=N, FILE_NAME must equal the ZIP basename.';
        end;

        /* Normal file or whole ZIP: calculate MD5 directly. */
        if status='OK' and extract='N' then do;
            if source_type='ZIP' then transfer_path=directory_path;
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
                md5=lowcase(hashing_file('MD5',fileref,4));
                if missing(md5) then do;
                    status='ERROR'; message=cats('MD5 calculation failed: ',sysmsg());
                end;
            end;
            rc=filename(fileref);
        end;

        /* ZIP + EXTRACT=Y: find, hash and validate matching members. */
        if status='OK' and source_type='ZIP' and extract='Y' then do;
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
                                member_md5=lowcase(hashing_file('MD5',memref,4));
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

            /* Extract only after all matching members pass MD5 validation. */
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

        keep row_id directory_path file_name md5 sftp_target extract source_type
             transfer_path transfer_name status message;
    run;

    /* Fail the complete batch if any row failed. */
    data _null_;
        set work._pm_results end=eof;
        retain errors 0;
        if status='ERROR' then do;
            errors+1;
            putlog 'ERROR: Manifest preparation failed. ' row_id= directory_path=
                   file_name= extract= message=;
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

    proc export
        data=&out(keep=row_id directory_path file_name md5 sftp_target extract)
        outfile="&result_xlsx"
        dbms=xlsx
        replace;
        sheet="&sheet";
    run;

%cleanup:
    proc datasets library=work nolist;
        delete _pm_:;
    quit;
%mend prepare_transfer_manifest;
