/*
 * excel_io.sas
 *
 * Reusable Excel input/output helpers for the SAS transfer workflow.
 */

%macro read_manifest_excel(
    xlsx=,
    sheet=,
    out=work.manifest,
    getnames=YES
);

    /* Import the workbook/sheet as-is first. */
    proc import
        datafile="&xlsx"
        out=work._manifest_raw
        dbms=xlsx
        replace;
        %if %length(%superq(sheet)) %then %do;
            sheet="&sheet";
        %end;
        getnames=&getnames;
    run;

    /* Resolve the first two imported columns dynamically. */
    proc sql noprint;
        select name
          into :_zipcol trimmed
          from dictionary.columns
         where libname='WORK'
           and memname='_MANIFEST_RAW'
           and varnum=1;

        select name
          into :_filecol trimmed
          from dictionary.columns
         where libname='WORK'
           and memname='_MANIFEST_RAW'
           and varnum=2;
    quit;

    /* Normalize the external Excel structure into the internal interface. */
    data &out;
        set work._manifest_raw;
        length zip_path $1024 file_name $512;

        row_id=_n_;
        zip_path=strip(vvaluex("&_zipcol"));
        file_name=strip(vvaluex("&_filecol"));

        if not missing(zip_path) and not missing(file_name);

        keep row_id zip_path file_name;
    run;

    proc datasets library=work nolist;
        delete _manifest_raw;
    quit;

%mend read_manifest_excel;


%macro write_manifest_excel(
    data=,
    xlsx=,
    sheet=MD5_Result
);

    proc export
        data=&data
        outfile="&xlsx"
        dbms=xlsx
        replace;
        sheet="&sheet";
    run;

%mend write_manifest_excel;
