/*
 * prepare_transfer_manifest.sas
 *
 * Excel -> validate -> MD5 -> optional ZIP extraction -> SFTP-ready dataset
 *       -> completed result workbook.
 *
 * The input manifest is intentionally opinionated:
 *   DIRECTORY_PATH, FILE_NAME, SFTP_TARGET and EXTRACT are selected by column
 *   index. MD5 is output only and is not read from the input workbook.
 *
 * HASHING_FILE() requires SAS 9.4M6+.
 */

/* Internal helper: resolve configured column indexes to imported SAS names. */
%macro _pm_resolve_columns(data=, directory_col=, file_col=, sftp_target_col=, extract_col=);
    proc contents data=&data out=work._pm_cols(keep=name varnum) noprint; run;

    proc sql noprint;
        select name into :_dircol trimmed
          from work._pm_cols where varnum=&directory_col;
        select name into :_filecol trimmed
          from work._pm_cols where varnum=&file_col;
        select name into :_sftpcol trimmed
          from work._pm_cols where varnum=&sftp_target_col;
        select name into :_extractcol trimmed
          from work._pm_cols where varnum=&extract_col;
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
    %local _dircol _filecol _sftpcol _extractcol
           _errors _outlib _outmem;

    /* A failed run must not leave an old successful result behind. */
    %let _outlib=%scan(&out,1,.);
    %let _outmem=%scan(&out,2,.);
    %if %length(&_outmem)=0 %then %do;
        %let _outmem=&_outlib;
        %let _outlib=WORK;
    %end;
    %if %sysfunc(exist(&out)) %then %do;
        proc datasets library=&_outlib nolist; delete &_outmem; quit;
    %end;

    /* 1. Import the manifest. Headers are required. */
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

    /* 2. Normalize rows and validate source/extraction rules. */
    data work._pm_manifest;
        set work._pm_raw;
        length directory_path $1024 file_name $1024 sftp_target $2048
               extract $1 source_type $3 rule_error $500;

        row_id=_n_;
        directory_path=strip(vvaluex("&_dircol"));
        file_name=strip(vvaluex("&_filecol"));
        sftp_target=strip(vvaluex("&_sftpcol"));
        extract=upcase(substr(strip(vvaluex("&_extractcol")),1,1));

        if missing(directory_path) or missing(file_name) then delete;
        source_type=ifc(prxmatch('/\.zip$/i',directory_path),'ZIP','DIR');

        if missing(sftp_target) then
            rule_error='SFTP_TARGET is required.';
        else if extract not in ('Y','N') then
            rule_error='EXTRACT must be Y or N.';
        else if source_type='DIR' and extract='Y' then
            rule_error='EXTRACT must be N when DIRECTORY_PATH is a directory.';
        else if source_type='ZIP' and extract='N' and
                upcase(scan(file_name,-1,'\/')) ne upcase(scan(directory_path,-1,'\/')) then
            rule_error='For ZIP + EXTRACT=N, FILE_NAME must equal the ZIP basename.';

        keep row_id directory_path file_name sftp_target extract source_type rule_error;
    run;

    /* 3. Handle invalid rows and direct files in one pass. */
    data work._pm_base;
        set work._pm_manifest;
        length transfer_path $2048 transfer_name $1024 computed_md5 $32
               error_message $500 ref $8;

        transfer_name=scan(file_name,-1,'\/');

        if not missing(rule_error) then error_message=rule_error;
        else if extract='N' then do;
            if source_type='ZIP' then transfer_path=directory_path;
            else transfer_path=cats(prxchange('s/[\\\/]+$//',1,directory_path),'\',file_name);

            ref='srcfile';
            rc=filename(ref,transfer_path);
            if rc ne 0 then error_message=cats('Cannot assign source file: ',sysmsg());
            else if not fexist(ref) then error_message='Source file does not exist.';
            else do;
                computed_md5=lowcase(hashing_file('MD5',ref,4));
                if missing(computed_md5) then error_message=cats('MD5 calculation failed: ',sysmsg());
            end;
            rc=filename(ref);
        end;
        else delete;  /* valid ZIP + EXTRACT=Y is handled below */

        keep row_id directory_path file_name sftp_target extract source_type
             transfer_path transfer_name computed_md5 error_message;
    run;

    /* 4. Scan ZIPs requested for extraction once. */
    proc sort data=work._pm_manifest(
        where=(rule_error='' and source_type='ZIP' and extract='Y')
        keep=directory_path
    ) out=work._pm_zips nodupkey;
        by directory_path;
    run;

    data work._pm_members;
        set work._pm_zips;
        length ref $8 member $2048 member_file $1024 scan_error 8;
        ref='inzip';
        rc=filename(ref,directory_path,'ZIP');
        if rc ne 0 then do; scan_error=1; output; end;
        else do;
            did=dopen(ref);
            if did=0 then do; scan_error=1; output; end;
            else do i=1 to dnum(did);
                member=dread(did,i);
                if substr(member,lengthn(member),1) ne '/' then do;
                    member_file=scan(member,-1,'/');
                    output;
                end;
            end;
            if did>0 then rc=dclose(did);
        end;
        rc=filename(ref);
        keep directory_path member member_file scan_error;
    run;

    proc sql;
        create table work._pm_matches as
        select m.row_id, m.directory_path, m.file_name, m.sftp_target,
               m.extract, m.source_type, z.member, z.scan_error
          from work._pm_manifest as m
          left join work._pm_members as z
            on m.directory_path=z.directory_path
           and (z.scan_error=1 or
                upcase(scan(m.file_name,-1,'\/'))=upcase(z.member_file))
         where m.rule_error='' and m.source_type='ZIP' and m.extract='Y'
         order by m.row_id,z.member;
    quit;

    data work._pm_hashes;
        set work._pm_matches;
        length ref $8 member_md5 $32;
        hash_error=(scan_error=1);

        if not hash_error and not missing(member) then do;
            ref='zipmem';
            rc=filename(ref,directory_path,'ZIP',cats('member=',quote(strip(member))));
            if rc ne 0 then hash_error=1;
            else do;
                member_md5=lowcase(hashing_file('MD5',ref,4));
                if missing(member_md5) then hash_error=1;
            end;
            rc=filename(ref);
        end;

        keep row_id directory_path file_name sftp_target extract source_type
             member member_md5 hash_error;
    run;

    proc sql;
        create table work._pm_zip_result as
        select row_id, directory_path, file_name, sftp_target, extract, source_type,
               count(member) as match_count,
               count(distinct member_md5) as md5_count,
               min(member_md5) as computed_md5 length=32,
               min(member) as selected_member length=2048,
               sum(hash_error) as hash_errors
          from work._pm_hashes
         group by row_id,directory_path,file_name,sftp_target,extract,source_type;
    quit;

    data work._pm_extracted;
        set work._pm_zip_result;
        length transfer_path $2048 transfer_name $1024 error_message $500
               inref outref $8;

        transfer_name=scan(file_name,-1,'\/');
        if hash_errors>0 then error_message='ZIP access or MD5 calculation failed.';
        else if match_count=0 then error_message='Requested file not found in ZIP.';
        else if md5_count>1 then error_message='Duplicate ZIP members have different MD5 values.';
        else do;
            transfer_path=cats(pathname('work'),'\_extract_',row_id,'_',transfer_name);
            inref='zinmem'; outref='xout';
            rc1=filename(inref,directory_path,'ZIP',cats('member=',quote(strip(selected_member))));
            rc2=filename(outref,transfer_path,'DISK','recfm=n');
            if rc1 ne 0 or rc2 ne 0 then error_message=cats('Cannot prepare extraction: ',sysmsg());
            else if fcopy(inref,outref) ne 0 then error_message=cats('Extraction failed: ',sysmsg());
            rc1=filename(inref); rc2=filename(outref);
        end;

        keep row_id directory_path file_name sftp_target extract source_type
             transfer_path transfer_name computed_md5 error_message;
    run;

    /* 5. Fail the complete batch if any row failed. */
    data work._pm_results;
        set work._pm_base work._pm_extracted;
    run;
    proc sort data=work._pm_results; by row_id; run;

    data _null_;
        set work._pm_results end=eof;
        retain errors 0;
        if not missing(error_message) then do;
            errors+1;
            putlog 'ERROR: Manifest preparation failed. ' row_id= directory_path= file_name=
                   extract= error_message=;
        end;
        if eof then call symputx('_errors',errors,'L');
    run;

    %if %sysevalf(%superq(_errors)=,boolean) %then %let _errors=0;
    %if &_errors>0 %then %do;
        %put ERROR: Transfer manifest preparation failed with &_errors error(s).;
        %goto cleanup;
    %end;

    /* 6. Publish the SFTP-ready data and completed manifest workbook. */
    data &out;
        set work._pm_results;
        md5=computed_md5;
        keep row_id directory_path file_name md5 sftp_target extract source_type
             transfer_path transfer_name;
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
        delete _pm_raw _pm_cols _pm_manifest _pm_base _pm_zips _pm_members
               _pm_matches _pm_hashes _pm_zip_result _pm_extracted _pm_results;
    quit;
%mend prepare_transfer_manifest;
