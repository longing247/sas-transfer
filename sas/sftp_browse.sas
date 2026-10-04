/*
 * sftp_browse.sas
 *
 * Creates a recursive file map of a remote SFTP folder.
 * Read-only: this program does not upload, modify, or delete remote files.
 */

%macro sftp_browse(
    host=,
    user=,
    remote_dir=,
    keyfile=,
    port=22,
    out=work.sftp_file_map
);
    %local _sftp_options;

    %let _sftp_options=-P &port -i "%superq(keyfile)";

    data &out;
        length path parent_path name $2048 type $9
               dirref childref $8 options $2048 message $500;
        stop;
    run;

    data work._sftp_queue;
        length path $2048;
        path=prxchange('s/\/+$/','1',strip("%superq(remote_dir)"));
        output;
    run;

    %do %while(1);
        %local _current _remaining;

        data _null_;
            set work._sftp_queue(obs=1);
            call symputx('_current',path,'L');
        run;

        %if not %length(%superq(_current)) %then %goto done;

        data work._sftp_queue;
            set work._sftp_queue(firstobs=2);
        run;

        filename sftpdir SFTP "%superq(_current)"
            host="&host"
            user="&user"
            optionsx="&_sftp_options";

        data work._sftp_level work._sftp_dirs(keep=path);
            length path parent_path name $2048 type $9
                   dirref childref $8 options $2048 message $500;
            parent_path="%superq(_current)";
            options="&_sftp_options";

            did=dopen('sftpdir');

            if did=0 then do;
                path=parent_path;
                name=scan(parent_path,-1,'/');
                type='ERROR';
                message=sysmsg();
                output work._sftp_level;
            end;
            else do i=1 to dnum(did);
                name=dread(did,i);

                if name not in ('.','..') then do;
                    path=cats(prxchange('s/\/+$/','1',strip(parent_path)),
                              '/',strip(name));

                    /* Try opening the entry as a directory. */
                    childref='sftpchld';
                    rc=filename(
                        childref,
                        path,
                        'SFTP',
                        cats(
                            'host=',quote("&host"),' ',
                            'user=',quote("&user"),' ',
                            'optionsx=',quote(trim(options))
                        )
                    );

                    child_did=dopen(childref);

                    if child_did>0 then do;
                        type='DIRECTORY';
                        message='';
                        output work._sftp_level;
                        output work._sftp_dirs;
                        rc_close=dclose(child_did);
                    end;
                    else do;
                        type='FILE';
                        message='';
                        output work._sftp_level;
                    end;

                    rc_clear=filename(childref);
                end;
            end;

            if did>0 then rc_close=dclose(did);

            keep path parent_path name type message;
        run;

        filename sftpdir clear;

        proc append base=&out data=work._sftp_level force;
        run;

        proc append base=work._sftp_queue data=work._sftp_dirs force;
        run;

        %let _current=;
        proc sql noprint;
            select count(*) into :_remaining trimmed
            from work._sftp_queue;
        quit;

        %if &_remaining=0 %then %goto done;
    %end;

%done:
    proc sort data=&out;
        by path;
    run;

    proc datasets library=work nolist;
        delete _sftp_queue _sftp_level _sftp_dirs;
    quit;
%mend sftp_browse;


/*
Example:

%sftp_browse(
    host=example.com,
    user=myuser,
    remote_dir=/incoming,
    keyfile=C:\keys\id_rsa,
    out=work.sftp_file_map
);

proc print data=work.sftp_file_map noobs;
run;
*/
