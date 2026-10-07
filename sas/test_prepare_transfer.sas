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

data work.prepare_transfer_test_results;
    length test_name $80 status $4 detail $500;
    stop;
run;

%macro assert(test_name, condition, detail);
    data work._test_one;
        length test_name $80 status $4 detail $500;
        test_name="&test_name";
        if &condition then status='PASS';
        else do;
            status='FAIL';
            call symputx('test_failures',
                         input(symget('test_failures'),best.)+1,'G');
        end;
        detail="&detail";
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
    PREPARED_DATASET_EXISTS,
    &have_result,
    prepare_transfer_result.sas7bdat exists
);

%assert(
    UPLOAD_SNAPSHOT_EXISTS,
    &have_snapshot,
    upload_snapshot.sas7bdat exists
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
        PREPARED_ROWS_EXIST,
        &row_count > 0,
        prepared dataset contains at least one row
    );

    %assert(
        REQUIRED_VALUES_PRESENT,
        &bad_required = 0,
        source path file name transfer path relative path and MD5 are populated
    );

    %assert(
        MD5_FORMAT,
        &bad_md5 = 0,
        every individual MD5 contains exactly 32 hexadecimal characters
    );

    %assert(
        DATA_TYPE,
        &bad_type = 0,
        every row is RAW_CRF or RAW_EXTERNAL
    );

    %assert(
        RELATIVE_PATH,
        &bad_relative = 0,
        every package path starts with RAW_CRF/ or RAW_EXTERNAL/
    );

    %assert(
        SOURCE_TYPE,
        &bad_source = 0,
        every source type is DIR or ZIP
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
        MD5_RECALCULATION,
        &bad_recalc = 0,
        persisted individual MD5 values match the prepared transfer files
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
        SNAPSHOT_TWO_ROWS,
        &snapshot_rows = 2,
        upload snapshot contains exactly package ZIP and MD5 CSV
    );

    %assert(
        SNAPSHOT_FILE_TYPES,
        &package_rows = 1 and &md5_rows = 1,
        upload snapshot contains one PACKAGE row and one MD5 row
    );

    %assert(
        SNAPSHOT_PATHS,
        &missing_upload = 0,
        both upload rows have file names and paths
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
        UPLOAD_FILES_EXIST,
        &missing_physical = 0,
        package ZIP and MD5 CSV physically exist
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
