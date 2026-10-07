/*
 * diagnose_hashing_file.sas
 *
 * Diagnostic helper for investigating physical files where SAS
 * HASHING_FILE() returns an MD5 that differs from byte-level Windows tools.
 *
 * Set file_path below to one problematic physical file and run this program.
 * It does not modify the source file.
 */

%let file_name=PET03_SiteList_20260921.csv;
%let file_path=&program_dir.\&file_name;

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

/*
 * Scan the physical file as raw bytes for hexadecimal 1A (Ctrl-Z / DOS EOF).
 * RECFM=N on this SAS host requires LRECL >= 256.
 */
filename _rawscan "&file_path" recfm=n lrecl=256;

data _null_;
    length block $256 byte $1;
    retain byte_position 0 ctrl_z_count 0 first_ctrl_z .;

    infile _rawscan recfm=n lrecl=256 length=n;
    input block $varying256. n;

    do j = 1 to n;
        byte = substr(block,j,1);
        byte_position + 1;

        if rank(byte)=26 then do;
            ctrl_z_count + 1;
            if missing(first_ctrl_z) then first_ctrl_z=byte_position;
            putlog 'CTRL-Z (1A) found at byte ' byte_position comma20.;
        end;
    end;
run;

data _null_;
    length path $2048;
    path="&file_path";
    putlog '===== CTRL-Z DIAGNOSTIC =====';
    putlog 'Raw scan completed for: ' path;
    putlog 'Review the log above for any CTRL-Z (1A) found messages.';
run;

filename _rawscan clear;

/*
 * Create a raw byte-for-byte copy in the program directory and profile
 * control/high bytes while copying.  The copy can then be checked with
 * HASHING_FILE() and independently with Get-FileHash.
 */
%let copy_path=&program_dir.\hash_test_copy.csv;

filename _rawsrc "&file_path" recfm=n lrecl=256;
filename _rawdst "&copy_path" recfm=n lrecl=256;

data _null_;
    length block $256 byte prev $1;
    retain total_bytes 0 cr_count 0 lf_count 0 crlf_count 0
           nul_count 0 high_byte_count 0 prev '';

    infile _rawsrc recfm=n lrecl=256 length=n end=eof;
    file _rawdst recfm=n lrecl=256;

    input block $varying256. n;
    put block $varying256. n;

    do j=1 to n;
        byte=substr(block,j,1);
        total_bytes+1;

        if rank(byte)=13 then cr_count+1;
        if rank(byte)=10 then lf_count+1;
        if prev='0D'x and byte='0A'x then crlf_count+1;
        if rank(byte)=0 then nul_count+1;
        if rank(byte)>=128 then high_byte_count+1;

        prev=byte;
    end;

    if eof then do;
        putlog '===== RAW BYTE PROFILE =====';
        putlog total_bytes=;
        putlog cr_count=;
        putlog lf_count=;
        putlog crlf_count=;
        putlog nul_count=;
        putlog high_byte_count=;
    end;
run;

filename _rawsrc clear;
filename _rawdst clear;

data _null_;
    length original copy $2048;
    length md5_original md5_copy $32;

    original="&file_path";
    copy="&copy_path";

    md5_original=hashing_file('MD5',original);
    md5_copy=hashing_file('MD5',copy);

    putlog '===== RAW COPY HASHING_FILE CHECK =====';
    putlog original=;
    putlog md5_original=;
    putlog copy=;
    putlog md5_copy=;
run;


/*
 * Deterministic one-byte copy diagnostic.
 *
 * Use this after confirming the source file size independently in Windows.
 * Set source_size to that exact byte count.  POINT= makes the loop finite:
 * SAS attempts exactly source_size byte reads and cannot wait for EOF.
 *
 * The result should be checked with Get-FileHash.  This test is diagnostic
 * only; it does not change the production transfer logic.
 */
%let source_size=74266;
%let byte_copy_path=&program_dir.\hash_test_bytecopy.csv;

filename _bytesrc "&file_path" recfm=n lrecl=256;
filename _bytedst "&byte_copy_path" recfm=n lrecl=256;

data _null_;
    length byte $1;

    do pos=1 to &source_size;
        infile _bytesrc recfm=n lrecl=256 point=pos;
        input byte $char1.;

        file _bytedst recfm=n lrecl=256;
        put byte $char1.;
    end;

    stop;
run;

filename _bytesrc clear;
filename _bytedst clear;

data _null_;
    length path $2048 md5 $32;

    path="&byte_copy_path";
    md5=hashing_file('MD5',path);

    putlog '===== DETERMINISTIC BYTE COPY CHECK =====';
    putlog path=;
    putlog md5=;
run;
