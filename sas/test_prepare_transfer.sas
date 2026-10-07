/*
 * test_prepare_transfer.sas
 *
 * Post-run unit/validation tests for prepare_transfer.sas.
 *
 * Run this after prepare_transfer.sas.  The tests use the persistent
 * prepare_transfer_result.sas7bdat and upload_snapshot.sas7bdat written
 * beside the program, so the production macros do not need to be rerun.
 *
 * Result:
 *   WORK.PREPARE_TRANSFER_TEST_RESULTS
 *   &program_dir.\prepare_transfer_test_result.sas7bdat
 */

%let test_failures=0;

%macro assert(test_name=, condition=, detail=);
    %local result;
    %let result=%eval(&condition);

    data work._test_one;
        length test_name $80 status $4 detail $500;
        test_name="&test_name";
        detail="&detail";

        if &result then status='PASS';
        else do;
            status='FAIL';
            call symputx('test_failures',
                         input(symget('test_failures'),best.)+1,'G');
        end;
    run;

    proc append base=work.prepare_transfer_test_results
                data=work._test_one force;
    run;
%mend assert;


/* ---------- Load persistent outputs ---------- */

libname testout "&program_dir";

%let have_result=%sysfunc(exist(testout.prepare_transfer_result));
%let have_snapshot=%sysfunc(exist(testout.upload_snapshot));

%assert(
    test_name=PREPARED_DATASET_EXISTS,
    condition=&have_result,
    detail=prepare_transfer_result.sas7bdat exists
);

%assert(
    test_name=UPLOAD_SNAPSHOT_EXISTS,
    condition=&have_snapshot,
    detail=upload_snapshot.sas7bdat exists
);

%if &have_result %then %do;

    data work._test_prepared;
        set testout.prepare_transfer_result;
    run;

    /* Every prepared row must have the fields required downstream. */
    proc sql noprint;
        select count(*) into :bad_required trimmed
        from work._test_prepared
        where missing(directory_path)
           or missing(file_name)
           or missing(transfer_path)
           or missing(relative_path)
           or missing(md5);

        select count(*) into :bad_md5 trimmed
        from work._test_prepared
        where not prxmatch('/^[0-9A-Fa-f]{32}$/',strip(md5));

        select count(*) into :bad_type trimmed
        from work._test_prepared
        where data_type not in ('RAW_CRF','RAW_EXTERNAL');

        select count(*) into :bad_relative trimmed
        from work._test_prepared
        where not (
            index(relative_path,'RAW_CRF/')=1 or
            index(relative_path,'RAW_EXTERNAL/')=1
        );

        select count(*) into :bad_source trimmed
        from work._test_prepared
        where source_type not in ('DIR','ZIP');

        select count(*) into :row_count trimmed
        from work._test_prepared;
    quit;

    %assert(
    test_name=PREPARED_ROWS_EXIST,
    condition=&row_count > 0,
    detail=prepared dataset contains at least one row
);

    %assert(
    test_name=REQUIRED_VALUES_PRESENT,
    condition=&bad_required = 0,
    detail=source path file name transfer path relative path and MD5 are populated
);

    %assert(
    test_name=MD5_FORMAT,
    condition=&bad_md5 = 0,
    detail=every individual MD5 contains exactly 32 hexadecimal characters
);

    %assert(
    test_name=DATA_TYPE,
    condition=&bad_type = 0,
    detail=every row is RAW_CRF or RAW_EXTERNAL
);

    %assert(
    test_name=RELATIVE_PATH,
    condition=&bad_relative = 0,
    detail=every package path starts with RAW_CRF/ or RAW_EXTERNAL/
);

    %assert(
    test_name=SOURCE_TYPE,
    condition=&bad_source = 0,
    detail=every source type is DIR or ZIP
);

    /*
     * Validate the conditional packaged-filename cleanup.
     * For rows whose source path contains uniqueString, the packaged
     * relative_path must no longer contain thingsToBeRemoved, regardless
     * of letter case.  Rows outside that path rule are not affected.
     */
    proc sql noprint;
        select count(*) into :rename_rows trimmed
        from work._test_prepared
        where index(upcase(directory_path),upcase('uniqueString')) > 0;

        select count(*) into :bad_rename trimmed
        from work._test_prepared
        where index(upcase(directory_path),upcase('uniqueString')) > 0
          and index(upcase(relative_path),upcase('thingsToBeRemoved')) > 0;
    quit;

    %assert(
    test_name=THINGS_TO_BE_REMOVED,
    condition=&bad_rename = 0,
    detail=thingsToBeRemoved is removed case-insensitively from applicable packaged filenames
);

    /*
     * Recalculate MD5 from each prepared transfer_path.
     * This also validates extracted ZIP members because transfer_path points
     * to the extracted binary file produced by prepare_transfer.sas.
     */
    data work._test_md5;
        set work._test_prepared;
        length test_md5 $32 ref $8;
        ref='tmd5';
        rc=filename(ref,transfer_path,'DISK','recfm=n lrecl=1048576');

        if rc=0 and fexist(ref) then
            test_md5=hashing_file('MD5',ref,4);

        rc=filename(ref);
        md5_match=(upcase(md5)=upcase(test_md5) and not missing(test_md5));
    run;

    proc sql noprint;
        select count(*) into :bad_recalc trimmed
        from work._test_md5
        where md5_match ne 1;
    quit;

    %assert(
    test_name=MD5_RECALCULATION,
    condition=&bad_recalc = 0,
    detail=persisted individual MD5 values match the prepared transfer files
);

%end;


/* ---------- Validate final upload snapshot ---------- */

%if &have_snapshot %then %do;

    data work._test_snapshot;
        set testout.upload_snapshot;
    run;

    proc sql noprint;
        select count(*) into :snapshot_rows trimmed
        from work._test_snapshot;

        select count(*) into :package_rows trimmed
        from work._test_snapshot
        where file_type='PACKAGE';

        select count(*) into :md5_rows trimmed
        from work._test_snapshot
        where file_type='MD5';

        select count(*) into :missing_upload trimmed
        from work._test_snapshot
        where missing(file_name) or missing(file_path);
    quit;

    %assert(
    test_name=SNAPSHOT_TWO_ROWS,
    condition=&snapshot_rows = 2,
    detail=upload snapshot contains exactly package ZIP and MD5 CSV
);

    %assert(
    test_name=SNAPSHOT_FILE_TYPES,
    condition=&package_rows = 1 and &md5_rows = 1,
    detail=upload snapshot contains one PACKAGE row and one MD5 row
);

    %assert(
    test_name=SNAPSHOT_PATHS,
    condition=&missing_upload = 0,
    detail=both upload rows have file names and paths
);

    data work._test_snapshot_files;
        set work._test_snapshot;
        length ref $8;
        ref='tupload';
        rc=filename(ref,file_path);
        file_exists=(rc=0 and fexist(ref));
        rc=filename(ref);
    run;

    proc sql noprint;
        select count(*) into :missing_physical trimmed
        from work._test_snapshot_files
        where file_exists ne 1;
    quit;

    %assert(
    test_name=UPLOAD_FILES_EXIST,
    condition=&missing_physical = 0,
    detail=package ZIP and MD5 CSV physically exist
);

%end;


/* ---------- Persist test result ---------- */

data testout.prepare_transfer_test_result;
    set work.prepare_transfer_test_results;
run;

libname testout clear;

title "prepare_transfer unit test results";
proc print data=work.prepare_transfer_test_results noobs;
run;
title;

%if &test_failures = 0 %then
    %put NOTE: ===== ALL PREPARE_TRANSFER TESTS PASSED =====;
%else
    %put ERROR: ===== &test_failures PREPARE_TRANSFER TEST(S) FAILED =====;
