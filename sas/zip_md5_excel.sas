/*
 * zip_md5_excel.sas
 *
 * Defines %zip_md5(), which works only with SAS datasets.
 * Excel read/write concerns are intentionally separated into excel_io.sas.
 *
 * Input dataset must contain:
 *   ZIP_PATH  - full path to the ZIP file
 *   FILE_NAME - basename to locate anywhere inside the ZIP
 *
 * Optional ROW_ID is preserved when present; otherwise one is generated.
 *
 * The target file may occur in any nested folder inside the ZIP.
 * If the same basename occurs multiple times, all instances are hashed.
 * A single MD5 is returned only when all matching instances have identical
 * content. Otherwise STATUS=MD5_MISMATCH.
 *
 * Requires SAS 9.4M6+ for HASHING_FILE().
 */

%macro zip_md5(
    data=,
    out=work.md5_result
);

    /* 1. Normalize the SAS input dataset. */
    data work._requests;
        set &data;
        length _zip_path $1024 _file_name $512;

        _zip_path=strip(vvaluex('zip_path'));
        _file_name=strip(vvaluex('file_name'));

        /* Preserve ROW_ID from the input when available. */
        if missing(vvaluex('row_id')) then _row_id=_n_;
        else _row_id=input(vvaluex('row_id'),best32.);

        if not missing(_zip_path) and not missing(_file_name);

        keep _row_id _zip_path _file_name;
        rename _row_id=row_id
               _zip_path=zip_path
               _file_name=file_name;
    run;

    /* 2. Scan each distinct ZIP only once. */
    proc sort
        data=work._requests(keep=zip_path)
        out=work._zips
        nodupkey;
        by zip_path;
    run;

    data work._members;
        set work._zips;
        length zipref $8 member $1024 member_file $512;

        zipref='zin';
        rc=filename(zipref,zip_path,'ZIP');

        if rc ne 0 then do;
            putlog 'ERROR: Cannot assign ZIP fileref. ' zip_path= rc=;
            putlog 'ERROR: ' sysmsg();
        end;
        else do;
            did=dopen(zipref);

            if did=0 then do;
                putlog 'ERROR: Cannot open ZIP. ' zip_path=;
                putlog 'ERROR: ' sysmsg();
            end;
            else do;
                do i=1 to dnum(did);
                    member=dread(did,i);

                    /* Directory entries end in /. */
                    if substr(member,lengthn(member),1) ne '/' then do;
                        member_file=scan(member,-1,'/');
                        output;
                    end;
                end;

                rc_close=dclose(did);
            end;
        end;

        rc_clear=filename(zipref);

        keep zip_path member member_file;
    run;

    /* 3. Match every requested basename against all nested ZIP members. */
    proc sql;
        create table work._matches as
        select r.row_id,
               r.zip_path,
               r.file_name,
               m.member
          from work._requests as r
          left join work._members as m
            on r.zip_path=m.zip_path
           and upcase(strip(r.file_name))=upcase(strip(m.member_file))
         order by r.row_id,m.member;
    quit;

    /* 4. Calculate MD5 for every matching member. */
    data work._hashes;
        set work._matches;
        length memref $8 member_md5 $32 hash_status $20;

        if missing(member) then do;
            member_md5='';
            hash_status='NOT_FOUND';
            output;
        end;
        else do;
            memref='zmember';

            rc=filename(
                memref,
                zip_path,
                'ZIP',
                cats('member=',quote(strip(member)))
            );

            if rc ne 0 then do;
                member_md5='';
                hash_status='HASH_ERROR';
                putlog 'ERROR: Cannot assign ZIP member. ' zip_path= member= rc=;
                putlog 'ERROR: ' sysmsg();
            end;
            else do;
                member_md5=lowcase(hashing_file('MD5',memref,4));

                if missing(member_md5) then do;
                    hash_status='HASH_ERROR';
                    putlog 'ERROR: HASHING_FILE failed. ' zip_path= member=;
                    putlog 'ERROR: ' sysmsg();
                end;
                else hash_status='OK';
            end;

            rc_clear=filename(memref);
            output;
        end;

        keep row_id zip_path file_name member member_md5 hash_status;
    run;

    /* 5. Summarize all matching instances for each request row. */
    proc sql;
        create table work._summary as
        select row_id,
               zip_path,
               file_name,
               count(member) as match_count,
               count(distinct case when hash_status='OK' then member_md5 end)
                   as distinct_md5_count,
               min(case when hash_status='OK' then member_md5 end)
                   as resolved_md5 length=32,
               sum(case when hash_status='HASH_ERROR' then 1 else 0 end)
                   as hash_errors
          from work._hashes
         group by row_id,zip_path,file_name
         order by row_id;
    quit;

    /* 6. Final validation result. */
    data &out;
        set work._summary;
        length md5 $32 status $40;

        if match_count=0 then do;
            md5='';
            status='NOT_FOUND';
        end;
        else if hash_errors>0 then do;
            md5='';
            status='HASH_ERROR';
        end;
        else if distinct_md5_count>1 then do;
            md5='';
            status='MD5_MISMATCH';
        end;
        else if match_count=1 then do;
            md5=resolved_md5;
            status='OK';
        end;
        else do;
            md5=resolved_md5;
            status='OK_IDENTICAL_DUPLICATES';
        end;

        keep row_id zip_path file_name md5 status match_count;
    run;

    proc datasets library=work nolist;
        delete _requests _zips _members _matches _hashes _summary;
    quit;

%mend zip_md5;
