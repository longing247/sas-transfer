/*
 * excel_io.sas
 *
 * Reusable Excel input/output helpers for the SAS transfer workflow.
 */

%macro read_manifest_excel(
    xlsx=,
    sheet=,
    out=work.manifest,
    zip_col=1,
    file_col=2,
    md5_col=0,
    sftp_target_col=0,
    getnames=YES
);
    %local _zipcol _filecol _md5col _sftpcol _maxcol;

    /*
     * Column arguments are 1-based Excel/imported-column positions.
     * MD5_COL=0 and SFTP_TARGET_COL=0 mean that the field is not present.
     */
    %let _maxcol=&zip_col;
    %if &file_col > &_maxcol %then %let _maxcol=&file_col;
    %if &md5_col > &_maxcol %then %let _maxcol=&md5_col;
    %if &sftp_target_col > &_maxcol %then %let _maxcol=&sftp_target_col;

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

    /* Resolve imported SAS variable names by physical column position. */
    proc sql noprint;
        select name into :_zipcol trimmed
          from dictionary.columns
         where libname='WORK' and memname='_MANIFEST_RAW' and varnum=&zip_col;

        select name into :_filecol trimmed
          from dictionary.columns
         where libname='WORK' and memname='_MANIFEST_RAW' and varnum=&file_col;

        %if &md5_col > 0 %then %do;
            select name into :_md5col trimmed
              from dictionary.columns
             where libname='WORK' and memname='_MANIFEST_RAW' and varnum=&md5_col;
        %end;

        %if &sftp_target_col > 0 %then %do;
            select name into :_sftpcol trimmed
              from dictionary.columns
             where libname='WORK' and memname='_MANIFEST_RAW' and varnum=&sftp_target_col;
        %end;
    quit;

    /* Fail early when a requested column position does not exist. */
    %if not %length(%superq(_zipcol)) %then %do;
        %put ERROR: ZIP_COL=&zip_col does not exist in the imported Excel sheet.;
        %return;
    %end;
    %if not %length(%superq(_filecol)) %then %do;
        %put ERROR: FILE_COL=&file_col does not exist in the imported Excel sheet.;
        %return;
    %end;
    %if &md5_col > 0 and not %length(%superq(_md5col)) %then %do;
        %put ERROR: MD5_COL=&md5_col does not exist in the imported Excel sheet.;
        %return;
    %end;
    %if &sftp_target_col > 0 and not %length(%superq(_sftpcol)) %then %do;
        %put ERROR: SFTP_TARGET_COL=&sftp_target_col does not exist in the imported Excel sheet.;
        %return;
    %end;

    data &out;
        set work._manifest_raw;
        length zip_path $1024
               file_path $1024
               md5 $32
               sftp_target $2048;

        row_id=_n_;
        zip_path=strip(vvaluex("&_zipcol"));
        file_path=strip(vvaluex("&_filecol"));

        %if &md5_col > 0 %then %do;
            md5=strip(vvaluex("&_md5col"));
        %end;
        %else %do;
            md5='';
        %end;

        %if &sftp_target_col > 0 %then %do;
            sftp_target=strip(vvaluex("&_sftpcol"));
        %end;
        %else %do;
            sftp_target='';
        %end;

        if not missing(zip_path) and not missing(file_path);

        keep row_id zip_path file_path md5 sftp_target;
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
