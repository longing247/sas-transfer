/*
 * source_md5.sas
 *
 * Defines %source_md5(). DIRECTORY_PATH may be either:
 *   1) a ZIP file path, or
 *   2) a normal directory path.
 *
 * Rules:
 * - ZIP + EXTRACT=N: FILE_NAME must equal the ZIP basename. Hash/transfer ZIP.
 * - ZIP + EXTRACT=Y: FILE_NAME identifies a member inside the ZIP. Hash the
 *   member, extract it to WORK, and transfer only the extracted member.
 * - Directory + EXTRACT=N: FILE_NAME is a file under DIRECTORY_PATH. Hash and
 *   transfer that file.
 * - Directory + EXTRACT=Y is invalid.
 *
 * Missing files, invalid rule combinations, ZIP access failures, hash failures,
 * or duplicate ZIP basenames with differing hashes raise ERRORs and no usable
 * output dataset is left behind.
 *
 * Requires SAS 9.4M6+ for HASHING_FILE().
 */

%macro source_md5(data=, out=work.md5_result);
    %local _errors _outlib _outmem;
    %let _outlib=%scan(&out,1,.);
    %let _outmem=%scan(&out,2,.);
    %if %length(&_outmem)=0 %then %do;
        %let _outmem=&_outlib;
        %let _outlib=WORK;
    %end;

    %if %sysfunc(exist(&out)) %then %do;
        proc datasets library=&_outlib nolist; delete &_outmem; quit;
    %end;

    data work._requests;
        set &data;
        length source_type $3 rule_error $500;
        directory_path=strip(directory_path);
        file_name=strip(file_name);
        extract=upcase(strip(extract));
        if missing(row_id) then row_id=_n_;
        source_type=ifc(prxmatch('/\.zip$/i',strip(directory_path)),'ZIP','DIR');
        rule_error='';

        if extract not in ('Y','N') then
            rule_error='EXTRACT must be Y or N.';
        else if source_type='DIR' and extract ne 'N' then
            rule_error='EXTRACT must be N when DIRECTORY_PATH is a directory.';
        else if source_type='ZIP' and extract='N' and
                upcase(scan(file_name,-1,'\/')) ne upcase(scan(directory_path,-1,'\/')) then
            rule_error='For ZIP + EXTRACT=N, FILE_NAME must equal the ZIP basename.';
    run;

    /* Direct files: a whole ZIP, or a file beneath a normal directory. */
    data work._direct;
        set work._requests(where=(rule_error='' and
                                  ((source_type='ZIP' and extract='N') or
                                   (source_type='DIR' and extract='N'))));
        length transfer_path $2048 transfer_name $1024 computed_md5 $32
               error_message $500 fileref $8;
        error_message='';
        transfer_name=scan(file_name,-1,'\/');

        if source_type='ZIP' then transfer_path=directory_path;
        else transfer_path=cats(prxchange('s/[\\\/]+$//',1,strip(directory_path)),
                                '\',strip(file_name));

        fileref='srcfile';
        rc=filename(fileref,transfer_path);
        if rc ne 0 then error_message=cats('Cannot assign source file: ',sysmsg());
        else if fexist(fileref)=0 then error_message='Source file does not exist.';
        else do;
            computed_md5=lowcase(hashing_file('MD5',fileref,4));
            if missing(computed_md5) then error_message=cats('MD5 calculation failed: ',sysmsg());
        end;
        rc_clear=filename(fileref);

        keep row_id directory_path file_name sftp_target extract source_type
             transfer_path transfer_name computed_md5 error_message;
    run;

    /* ZIP members requested for extraction. Scan each ZIP once. */
    proc sort data=work._requests(
        where=(rule_error='' and source_type='ZIP' and extract='Y')
        keep=directory_path
    ) out=work._zips nodupkey;
        by directory_path;
    run;

    data work._members;
        set work._zips;
        length zipref $8 member $2048 member_file $1024 scan_error 8;
        zipref='zin'; scan_error=0;
        rc=filename(zipref,directory_path,'ZIP');
        if rc ne 0 then do; scan_error=1; output; end;
        else do;
            did=dopen(zipref);
            if did=0 then do; scan_error=1; output; end;
            else do;
                do i=1 to dnum(did);
                    member=dread(did,i);
                    if substr(member,lengthn(member),1) ne '/' then do;
                        member_file=scan(member,-1,'/');
                        output;
                    end;
                end;
                rc_close=dclose(did);
            end;
        end;
        rc_clear=filename(zipref);
        keep directory_path member member_file scan_error;
    run;

    proc sql;
        create table work._matches as
        select r.row_id, r.directory_path, r.file_name, r.sftp_target,
               r.extract, r.source_type, m.member, m.scan_error
          from work._requests as r
          left join work._members as m
            on r.directory_path=m.directory_path
           and (m.scan_error=1 or
                upcase(scan(r.file_name,-1,'\/'))=upcase(m.member_file))
         where r.rule_error='' and r.source_type='ZIP' and r.extract='Y'
         order by r.row_id,m.member;
    quit;

    data work._member_hashes;
        set work._matches;
        length memref $8 member_md5 $32 hash_error 8;
        hash_error=0;
        if scan_error=1 then hash_error=1;
        else if not missing(member) then do;
            memref='zmember';
            rc=filename(memref,directory_path,'ZIP',cats('member=',quote(strip(member))));
            if rc ne 0 then hash_error=1;
            else do;
                member_md5=lowcase(hashing_file('MD5',memref,4));
                if missing(member_md5) then hash_error=1;
            end;
            rc_clear=filename(memref);
        end;
        keep row_id directory_path file_name sftp_target extract source_type
             member member_md5 hash_error;
    run;

    proc sql;
        create table work._member_summary as
        select row_id, directory_path, file_name, sftp_target, extract, source_type,
               count(member) as match_count,
               count(distinct member_md5) as distinct_md5_count,
               min(member_md5) as computed_md5 length=32,
               min(member) as selected_member length=2048,
               sum(hash_error) as hash_errors
          from work._member_hashes
         group by row_id,directory_path,file_name,sftp_target,extract,source_type;
    quit;

    data work._extracted;
        set work._member_summary;
        length transfer_path $2048 transfer_name $1024 error_message $500
               inref outref $8;
        error_message='';
        transfer_name=scan(file_name,-1,'\/');

        if hash_errors>0 then error_message='ZIP access or MD5 calculation failed.';
        else if match_count=0 then error_message='Requested file not found in ZIP.';
        else if distinct_md5_count>1 then
            error_message='Duplicate filename instances in ZIP have different MD5 values.';
        else do;
            transfer_path=cats(pathname('work'),'\_extract_',strip(put(row_id,best.)),
                               '_',transfer_name);
            inref='zinmem'; outref='xout';
            rc_in=filename(inref,directory_path,'ZIP',
                           cats('member=',quote(strip(selected_member))));
            rc_out=filename(outref,transfer_path,'DISK','recfm=n');
            if rc_in ne 0 or rc_out ne 0 then error_message=cats('Cannot prepare extraction: ',sysmsg());
            else do;
                rc_copy=fcopy(inref,outref);
                if rc_copy ne 0 then error_message=cats('Extraction failed: ',sysmsg());
            end;
            rc1=filename(inref); rc2=filename(outref);
        end;

        keep row_id directory_path file_name sftp_target extract source_type
             transfer_path transfer_name computed_md5 error_message;
    run;

    /* Invalid rule combinations are also represented as failed rows. */
    data work._rule_errors;
        set work._requests(where=(rule_error ne ''));
        length transfer_path $2048 transfer_name $1024 computed_md5 $32 error_message $500;
        transfer_name=scan(file_name,-1,'\/');
        error_message=rule_error;
        keep row_id directory_path file_name sftp_target extract source_type
             transfer_path transfer_name computed_md5 error_message;
    run;

    data work._all_results;
        set work._direct work._extracted work._rule_errors;
    run;

    proc sort data=work._all_results; by row_id; run;

    data _null_;
        set work._all_results end=eof;
        retain errors 0;
        if not missing(error_message) then do;
            errors+1;
            putlog 'ERROR: Source validation failed. ' row_id= directory_path= file_name=
                   extract= error_message=;
        end;
        if eof then call symputx('_errors',errors,'L');
    run;

    %if %sysevalf(%superq(_errors)=,boolean) %then %let _errors=0;
    %if &_errors > 0 %then %do;
        %put ERROR: Source MD5 preparation failed with &_errors error(s).;
        proc datasets library=work nolist;
            delete _requests _direct _zips _members _matches _member_hashes
                   _member_summary _extracted _rule_errors _all_results;
        quit;
        %return;
    %end;

    data &out;
        set work._all_results;
        md5=computed_md5;
        keep row_id directory_path file_name md5 sftp_target extract source_type
             transfer_path transfer_name;
    run;

    proc datasets library=work nolist;
        delete _requests _direct _zips _members _matches _member_hashes
               _member_summary _extracted _rule_errors _all_results;
    quit;
%mend source_md5;
