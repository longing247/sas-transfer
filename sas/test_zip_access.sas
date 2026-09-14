/*
 * test_zip_access.sas
 *
 * Standalone diagnostic for testing whether the SAS ZIP filename engine
 * can open a ZIP file and list its members with DOPEN/DREAD.
 *
 * Replace the path below with the ZIP file you want to test.
 */

filename inzip ZIP "P:\path\to\zip_folder.zip";

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
