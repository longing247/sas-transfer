/*
 * excel_io.sas
 * Reusable Excel input/output helpers for the SAS transfer workflow.
 */

%macro read_manifest_excel(
    xlsx=,
    sheet=,
    out=work.manifest,
    directory_col=1,
    file_col=2,
    md5_col=3,
    sftp_target_col=4,
    extract_col=5,
    getnames=YES
);
    %local _dircol _filecol _md5col _sftpcol _extractcol;

    proc import datafile="&xlsx" out=work._manifest_raw dbms=xlsx replace;
        %if %length(%superq(sheet)) %then %do; sheet="&sheet"; %end;
        getnames=&getnames;
    run;

    proc sql noprint;
        select name into :_dircol trimmed from dictionary.columns
         where libname='WORK' and memname='_MANIFEST_RAW' and varnum=&directory_col;
        select name into :_filecol trimmed from dictionary.columns
         where libname='WORK' and memname='_MANIFEST_RAW' and varnum=&file_col;
        %if &md5_col > 0 %then %do;
            select name into :_md5col trimmed from dictionary.columns
             where libname='WORK' and memname='_MANIFEST_RAW' and varnum=&md5_col;
        %end;
        %if &sftp_target_col > 0 %then %do;
            select name into :_sftpcol trimmed from dictionary.columns
             where libname='WORK' and memname='_MANIFEST_RAW' and varnum=&sftp_target_col;
        %end;
        select name into :_extractcol trimmed from dictionary.columns
         where libname='WORK' and memname='_MANIFEST_RAW' and varnum=&extract_col;
    quit;

    %if not %length(%superq(_dircol)) or not %length(%superq(_filecol)) or
        not %length(%superq(_extractcol)) %then %do;
        %put ERROR: DIRECTORY_COL, FILE_COL, or EXTRACT_COL does not exist in the imported sheet.;
        %return;
    %end;

    data &out;
        set work._manifest_raw;
        length directory_path $1024 file_name $1024 md5 $32
               sftp_target $2048 extract $1;
        row_id=_n_;
        directory_path=strip(vvaluex("&_dircol"));
        file_name=strip(vvaluex("&_filecol"));
        %if &md5_col > 0 %then %do; md5=strip(vvaluex("&_md5col")); %end;
        %else %do; md5=''; %end;
        %if &sftp_target_col > 0 %then %do; sftp_target=strip(vvaluex("&_sftpcol")); %end;
        %else %do; sftp_target=''; %end;
        extract=upcase(substr(strip(vvaluex("&_extractcol")),1,1));
        if not missing(directory_path) and not missing(file_name);
        keep row_id directory_path file_name md5 sftp_target extract;
    run;

    proc datasets library=work nolist; delete _manifest_raw; quit;
%mend read_manifest_excel;

%macro write_manifest_excel(data=, xlsx=, sheet=MD5_Result);
    proc export
        data=&data(keep=row_id directory_path file_name md5 sftp_target extract)
        outfile="&xlsx"
        dbms=xlsx
        replace;
        sheet="&sheet";
    run;
%mend write_manifest_excel;
