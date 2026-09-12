/*
 * zip_md5_excel.sas
 *
 * Defines %zip_md5(), which works only with SAS datasets.
 * Excel read/write concerns are separated into excel_io.sas.
 *
 * Input dataset must contain ZIP_PATH and FILE_NAME.
 * Optional ROW_ID is preserved when present; otherwise one is generated.
 *
 * The target may be anywhere in a nested ZIP folder. If the same basename
 * occurs multiple times, every instance is hashed. Identical duplicates are
 * accepted; missing files, differing duplicate hashes, ZIP access failures,
 * and hash failures raise an ERROR and abort the macro.
 *
 * Requires SAS 9.4M6+ for HASHING_FILE().
 */

%macro zip_md5(data=, out=work.md5_result);
    %local _validation_errors;

    data work._requests;
        set &data;
        length _zip_path $1024 _file_name $512;
        _zip_path=strip(vvaluex('zip_path'));
        _file_name=strip(vvaluex('file_name'));
        if missing(vvaluex('row_id')) then _row_id=_n_;
        else _row_id=input(vvaluex('row_id'),best32.);
        if not missing(_zip_path) and not missing(_file_name);
        keep _row_id _zip_path _file_name;
        rename _row_id=row_id _zip_path=zip_path _file_name=file_name;
    run;

    proc sort data=work._requests(keep=zip_path) out=work._zips nodupkey;
        by zip_path;
    run;

    data work._members;
        set work._zips;
        length zipref $8 member $1024 member_file $512 scan_error 8;
        zipref='zin';
        scan_error=0;
        rc=filename(zipref,zip_path,'ZIP');
        if rc ne 0 then do;
            scan_error=1;
            putlog 'ERROR: Cannot assign ZIP fileref. ' zip_path= rc=;
            putlog 'ERROR: ' sysmsg();
            output;
        end;
        else do;
            did=dopen(zipref);
            if did=0 then do;
                scan_error=1;
                putlog 'ERROR: Cannot open ZIP. ' zip_path=;
                putlog 'ERROR: ' sysmsg();
                output;
            end;
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
        keep zip_path member member_file scan_error;
    run;

    proc sql;
        create table work._matches as
        select r.row_id, r.zip_path, r.file_name, m.member, m.scan_error
          from work._requests as r
          left join work._members as m
            on r.zip_path=m.zip_path
           and (m.scan_error=1 or
                upcase(strip(r.file_name))=upcase(strip(m.member_file)))
         order by r.row_id,m.member;
    quit;

    data work._hashes;
        set work._matches;
        length memref $8 member_md5 $32;
        hash_error=0;

        if scan_error=1 then hash_error=1;
        else if not missing(member) then do;
            memref='zmember';
            rc=filename(memref,zip_path,'ZIP',cats('member=',quote(strip(member))));
            if rc ne 0 then do;
                hash_error=1;
                putlog 'ERROR: Cannot assign ZIP member. ' zip_path= member= rc=;
                putlog 'ERROR: ' sysmsg();
            end;
            else do;
                member_md5=lowcase(hashing_file('MD5',memref,4));
                if missing(member_md5) then do;
                    hash_error=1;
                    putlog 'ERROR: HASHING_FILE failed. ' zip_path= member=;
                    putlog 'ERROR: ' sysmsg();
                end;
            end;
            rc_clear=filename(memref);
        end;
        keep row_id zip_path file_name member member_md5 hash_error;
    run;

    proc sql;
        create table work._summary as
        select row_id, zip_path, file_name,
               count(member) as match_count,
               count(distinct member_md5) as distinct_md5_count,
               min(member_md5) as md5 length=32,
               sum(hash_error) as hash_errors
          from work._hashes
         group by row_id,zip_path,file_name
         order by row_id;
    quit;

    /* Collect all validation failures before aborting, so the log identifies
       every problematic manifest row in one run. */
    data _null_;
        set work._summary end=eof;
        retain errors 0;

        if hash_errors>0 then do;
            errors+1;
            putlog 'ERROR: ZIP access or MD5 calculation failed. ' row_id= zip_path= file_name=;
        end;
        else if match_count=0 then do;
            errors+1;
            putlog 'ERROR: Requested file not found in ZIP. ' row_id= zip_path= file_name=;
        end;
        else if distinct_md5_count>1 then do;
            errors+1;
            putlog 'ERROR: Duplicate filename instances have different MD5 values. '
                   row_id= zip_path= file_name= match_count= distinct_md5_count=;
        end;

        if eof then call symputx('_validation_errors',errors,'L');
    run;

    %if %sysevalf(%superq(_validation_errors)=,boolean) %then %let _validation_errors=0;

    %if &_validation_errors > 0 %then %do;
        %put ERROR: ZIP MD5 validation failed with &_validation_errors error(s).;
        proc datasets library=work nolist;
            delete _requests _zips _members _matches _hashes _summary;
        quit;
        %return;
    %end;

    /* Successful output is intentionally minimal: no STATUS column. */
    data &out;
        set work._summary;
        keep row_id zip_path file_name md5;
    run;

    proc datasets library=work nolist;
        delete _requests _zips _members _matches _hashes _summary;
    quit;
%mend zip_md5;
