/*
 * diagnose_hashing_file.sas
 *
 * Diagnostic helper for investigating physical files where SAS
 * HASHING_FILE() returns an MD5 that differs from byte-level Windows tools.
 *
 * Set file_path below to one problematic physical file and run this program.
 * It does not modify the source file.
 */

%let file_path=P:\path\to\failing.csv;

data _null_;
    length path $2048 md5_default md5_flag0 $32;
    length optname value $256 msg $500;

    path = symget('file_path');

    exists = fileexist(path);
    md5_default = hashing_file('MD5', path);
    md5_flag0   = hashing_file('MD5', path, 0);

    put '===== HASHING_FILE DIAGNOSTIC =====';
    put path=;
    put exists=;
    put md5_default=;
    put md5_flag0=;

    rc = filename('diagfile', path);

    if rc ne 0 then do;
        put 'ERROR: FILENAME assignment failed.';
        msg = sysmsg();
        putlog 'ERROR: ' msg;
    end;
    else do;
        fid = fopen('diagfile', 'I', 1, 'B');

        if fid > 0 then do;
            nopts = foptnum(fid);

            put '===== FOPEN/FINFO ATTRIBUTES =====';

            do i = 1 to nopts;
                optname = foptname(fid, i);
                value   = finfo(fid, optname);
                put i= optname= value=;
            end;

            rc = fclose(fid);
        end;
        else do;
            put 'ERROR: FOPEN failed.';
            msg = sysmsg();
            putlog 'ERROR: ' msg;
        end;

        rc = filename('diagfile');
    end;
run;
