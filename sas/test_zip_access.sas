/*
 * test_zip_access.sas
 *
 * Standalone diagnostic for testing ZIP access and reading one member.
 * Replace ZIP_PATH and ZIP_MEMBER below with the values from your test.
 */

%let zip_path=P:\path\to\zip_folder.zip;
%let zip_member=zip_folder/test.txt;

/* 1. Open ZIP and list members. */
filename inzip ZIP "&zip_path";

data _null_;
    length member $2048;

    did=dopen('inzip');
    putlog '--- ZIP ACCESS TEST ---';
    putlog 'DID=' did;

    if did > 0 then do;
        n=dnum(did);
        putlog 'MEMBERS=' n;

        do i=1 to n;
            member=dread(did,i);
            putlog member=;
        end;

        rc=dclose(did);
    end;
    else do;
        putlog 'ERROR: ZIP could not be opened with DOPEN.';
    end;
run;

filename inzip clear;

/* 2. Access one known member directly. */
filename zipmem ZIP "&zip_path" member="&zip_member";

data _null_;
    length md5 $32;

    putlog '--- ZIP MEMBER TEST ---';
    putlog "ZIP_MEMBER=&zip_member";

    exists=fexist('zipmem');
    putlog 'FEXIST=' exists;

    if exists then do;
        md5=hashing_file('MD5','zipmem',4);
        putlog 'MD5=' md5;
    end;
    else do;
        putlog 'ERROR: ZIP member is not available.';
    end;
run;

filename zipmem clear;
