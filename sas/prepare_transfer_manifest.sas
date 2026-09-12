/*
 * prepare_transfer_manifest.sas
 *
 * One public macro for the complete local preparation stage:
 *   Excel -> validate -> MD5 -> optional ZIP extraction -> result dataset
 *         -> update MD5 in the original Excel sheet.
 *
 * DIRECTORY_PATH may be a .zip file or a normal Windows directory.
 * EXTRACT=Y is valid only for a file inside a ZIP.
 *
 * Windows SAS is required for the in-place Excel update because this uses
 * the EXCEL LIBNAME engine. HASHING_FILE() requires SAS 9.4M6+.
 */

%macro prepare_transfer_manifest(
    xlsx=,
    sheet=,
    out=work.md5_result,
    directory_col=1,
    file_col=2,
    md5_col=3,
    sftp_target_col=4,
    extract_col=5,
    getnames=YES
);
    %local _dircol _filecol _md5col _sftpcol _extractcol
           _dirlit _filelit _md5lit _extractlit
           _errors _outlib _outmem _excel_rc;

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

    /* 1. Read the manifest and map configured Excel columns by position. */
    proc import datafile="&xlsx" out=work._pm_raw dbms=xlsx replace;
        %if %length(%superq(sheet)) %then %do; sheet="&sheet"; %end;
        getnames=&getnames;
    run;

    proc contents data=work._pm_raw out=work._pm_cols(keep=name varnum) noprint; run;

    data _null_;
        set work._pm_cols;
        if varnum=&directory_col then do;
            call symputx('_dircol',name,'L');
            call symputx('_dirlit',nliteral(name),'L');
        end;
        if varnum=&file_col then do;
            call symputx('_filecol',name,'L');
            call symputx('_filelit',nliteral(name),'L');
        end;
        if varnum=&md5_col then do;
            call symputx('_md5col',name,'L');
            call symputx('_md5lit',nliteral(name),'L');
        end;
        if &sftp_target_col>0 and varnum=&sftp_target_col then
            call symputx('_sftpcol',name,'L');
        if varnum=&extract_col then do;
            call symputx('_extractcol',name,'L');
            call symputx('_extractlit',nliteral(name),'L');
        end;
    run;

    %if not %length(%superq(_dircol)) or
        not %length(%superq(_filecol)) or
        not %length(%superq(_md5col)) or
        not %length(%superq(_extractcol)) or
        (&sftp_target_col>0 and not %length(%superq(_sftpcol))) %then %do;
        %put ERROR: One or more requested Excel column numbers do not exist.;
        %goto cleanup;
    %end;

    /* 2. Normalize rows and validate the source/extraction rules. */
    data work._pm_manifest;
        set work._pm_raw;
        length directory_path $1024 file_name $1024 md5 $32
               sftp_target $2048 extract $1 source_type $3 rule_error $500;

        row_id=_n_;
        directory_path=strip(vvaluex("&_dircol"));
        file_name=strip(vvaluex("&_filecol"));
        md5=strip(vvaluex("&_md5col"));
        extract=upcase(substr(strip(vvaluex("&_extractcol")),1,1));
        %if &sftp_target_col>0 %then %do;
            sftp_target=strip(vvaluex("&_sftpcol"));
        %end;
        %else %do;
            sftp_target='';
        %end;

        if missing(directory_path) or missing(file_name) then delete;
        source_type=ifc(prxmatch('/\.zip$/i',directory_path),'ZIP','DIR');

        if extract not in ('Y','N') then
            rule_error='EXTRACT must be Y or N.';
        else if source_type='DIR' and extract='Y' then
            rule_error='EXTRACT must be N when DIRECTORY_PATH is a directory.';
        else if source_type='ZIP' and extract='N' and
                upcase(scan(file_name,-1,'\/')) ne upcase(scan(directory_path,-1,'\/')) then
            rule_error='For ZIP + EXTRACT=N, FILE_NAME must equal the ZIP basename.';

        keep row_id directory_path file_name md5 sftp_target extract source_type rule_error;
    run;

    /* 3. Direct files: whole ZIPs and files beneath normal directories. */
    data work._pm_direct;
        set work._pm_manifest(where=(rule_error='' and extract='N'));
        length transfer_path $2048 transfer_name $1024 computed_md5 $32
               error_message $500 ref $8;

        transfer_name=scan(file_name,-1,'\/');
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

        keep row_id directory_path file_name sftp_target extract source_type
             transfer_path transfer_name computed_md5 error_message;
    run;

    /* 4. ZIP extraction requests: scan each ZIP once. */
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

    /* Extract one copy only after duplicate members have passed MD5 validation. */
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

    data work._pm_rule_errors;
        set work._pm_manifest(where=(rule_error ne ''));
        length transfer_path $2048 transfer_name $1024 computed_md5 $32 error_message $500;
        transfer_name=scan(file_name,-1,'\/');
        error_message=rule_error;
        keep row_id directory_path file_name sftp_target extract source_type
             transfer_path transfer_name computed_md5 error_message;
    run;

    data work._pm_results;
        set work._pm_direct work._pm_extracted work._pm_rule_errors;
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

    /* 5. Publish the SFTP-ready SAS result. */
    data &out;
        set work._pm_results;
        md5=computed_md5;
        keep row_id directory_path file_name md5 sftp_target extract source_type
             transfer_path transfer_name;
    run;

    /*
     * 6. Update only the MD5 column in the original workbook.
     *
     * The Windows EXCEL engine can update an existing worksheet. SCANTEXT=NO
     * enables update access and FILELOCK=YES prevents concurrent Excel edits.
     * Matching uses the manifest source fields, so no row-number column has to
     * be added to the workbook.
     */
    options validvarname=any validmemname=extend;
    libname _pmxls excel path="&xlsx" header=yes scanttext=no mixed=yes filelock=yes;
    %let _excel_rc=&syslibrc;

    %if &_excel_rc ne 0 %then %do;
        %put ERROR: Cannot open the Excel workbook for MD5 update. Close the workbook and retry.;
        %goto cleanup;
    %end;

    proc sql;
        update _pmxls."&sheet.$"n as x
           set &_md5lit = (
               select r.md5
                 from &out as r
                where strip(cats(x.&_dirlit))=r.directory_path
                  and strip(cats(x.&_filelit))=r.file_name
                  and upcase(substr(strip(cats(x.&_extractlit)),1,1))=r.extract
           )
         where exists (
               select 1
                 from &out as r
                where strip(cats(x.&_dirlit))=r.directory_path
                  and strip(cats(x.&_filelit))=r.file_name
                  and upcase(substr(strip(cats(x.&_extractlit)),1,1))=r.extract
         );
    quit;

    libname _pmxls clear;

%cleanup:
    proc datasets library=work nolist;
        delete _pm_raw _pm_cols _pm_manifest _pm_direct _pm_zips _pm_members
               _pm_matches _pm_hashes _pm_zip_result _pm_extracted
               _pm_rule_errors _pm_results;
    quit;
%mend prepare_transfer_manifest;
