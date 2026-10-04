/*
 * sftp_test_crud.sas
 *
 * CRUD qualification test for the SAS SFTP connection.
 *
 * IMPORTANT:
 * - Use only with a dedicated TEST_ROOT.
 * - The macro creates and deletes only TEST_FOLDER directly below TEST_ROOT.
 * - No production transfer files are used.
 *
 * Tests:
 *   1. READ    - open TEST_ROOT
 *   2. CREATE  - create TEST_FOLDER and upload a small text file
 *   3. READ    - verify the uploaded file exists
 *   4. UPDATE  - overwrite the file with different content
 *   5. READ    - verify the updated remote file MD5 matches the local MD5
 *   6. DELETE  - delete the test file
 *   7. DELETE  - delete TEST_FOLDER
 */

%macro sftp_test_crud(
    host=,
    user=,
    test_root=,
    keyfile=,
    port=22,
    test_folder=sas_crud_test,
    out=work.sftp_crud_test
);
    %local _options _test_dir;

    %let _options=-P &port -i "%superq(keyfile)";
    %let _test_dir=%sysfunc(prxchange(s/\/+$/,,%superq(test_root)))/%superq(test_folder);

    data &out;
        length test $32 status $8 message $500;
        stop;
    run;

    /* Test 1: READ the test root. */
    filename sftproot SFTP "%superq(test_root)"
        host="&host"
        user="&user"
        optionsx="&_options";

    data work._crud_result;
        length test $32 status $8 message $500;
        test='READ_ROOT';
        did=dopen('sftproot');

        if did>0 then do;
            status='PASS';
            message='Test root opened successfully.';
            rc=dclose(did);
        end;
        else do;
            status='FAIL';
            message=sysmsg();
        end;

        output;
    run;

    proc append base=&out data=work._crud_result force; run;

    /* Test 2: CREATE a dedicated test folder. */
    data work._crud_result;
        length test $32 status $8 message $500;
        test='CREATE_FOLDER';
        did=dopen('sftproot');

        if did>0 then do;
            newdir=dcreate("%superq(test_folder)",'sftproot');

            if not missing(newdir) then do;
                status='PASS';
                message='Test folder created.';
            end;
            else do;
                status='FAIL';
                message=sysmsg();
            end;

            rc=dclose(did);
        end;
        else do;
            status='FAIL';
            message=sysmsg();
        end;

        output;
    run;

    proc append base=&out data=work._crud_result force; run;
    filename sftproot clear;

    /* Create a small local file for the upload test. */
    filename crudloc temp recfm=n;

    data _null_;
        file crudloc;
        put 'SAS SFTP CRUD TEST - VERSION 1';
    run;

    /* Test 3: CREATE/upload the remote file. */
    filename crudrem SFTP "&_test_dir/crud_test.txt"
        host="&host"
        user="&user"
        recfm=n
        optionsx="&_options";

    data work._crud_result;
        length test $32 status $8 message $500;
        test='CREATE_FILE';
        rc=fcopy('crudloc','crudrem');

        if rc=0 then do;
            status='PASS';
            message='Test file uploaded.';
        end;
        else do;
            status='FAIL';
            message=sysmsg();
        end;

        output;
    run;

    proc append base=&out data=work._crud_result force; run;
    filename crudrem clear;

    /* Test 4: READ/verify the uploaded file exists. */
    filename crudrem SFTP "&_test_dir/crud_test.txt"
        host="&host"
        user="&user"
        recfm=n
        optionsx="&_options";

    data work._crud_result;
        length test $32 status $8 message $500;
        test='READ_FILE';

        if fexist('crudrem') then do;
            status='PASS';
            message='Uploaded test file exists.';
        end;
        else do;
            status='FAIL';
            message=sysmsg();
        end;

        output;
    run;

    proc append base=&out data=work._crud_result force; run;
    filename crudrem clear;

    /* Replace local content for the UPDATE test. */
    data _null_;
        file crudloc;
        put 'SAS SFTP CRUD TEST - VERSION 2';
    run;

    /* Test 5: UPDATE/overwrite the remote file. */
    filename crudrem SFTP "&_test_dir/crud_test.txt"
        host="&host"
        user="&user"
        recfm=n
        optionsx="&_options";

    data work._crud_result;
        length test $32 status $8 message $500;
        test='UPDATE_FILE';
        rc=fcopy('crudloc','crudrem');

        if rc=0 then do;
            status='PASS';
            message='Test file overwritten.';
        end;
        else do;
            status='FAIL';
            message=sysmsg();
        end;

        output;
    run;

    proc append base=&out data=work._crud_result force; run;

    /* Test 6: verify UPDATE byte-for-byte using MD5. */
    data work._crud_result;
        length test $32 status $8 message $500
               local_md5 remote_md5 $32;
        test='VERIFY_UPDATE_MD5';

        local_md5=hashing_file('MD5','crudloc',4);
        remote_md5=hashing_file('MD5','crudrem',4);

        if not missing(local_md5) and local_md5=remote_md5 then do;
            status='PASS';
            message='Local and remote MD5 values match.';
        end;
        else do;
            status='FAIL';
            message=cats('MD5 mismatch. local=',local_md5,
                         ' remote=',remote_md5);
        end;

        output;
    run;

    proc append base=&out data=work._crud_result force; run;

    /* Test 7: DELETE the test file. */
    data work._crud_result;
        length test $32 status $8 message $500;
        test='DELETE_FILE';

        if fexist('crudrem') then rc=fdelete('crudrem');
        else rc=1;

        if rc=0 then do;
            status='PASS';
            message='Test file deleted.';
        end;
        else do;
            status='FAIL';
            message=sysmsg();
        end;

        output;
    run;

    proc append base=&out data=work._crud_result force; run;
    filename crudrem clear;
    filename crudloc clear;

    /* Test 8: DELETE the now-empty test folder. */
    filename sftproot SFTP "%superq(test_root)"
        host="&host"
        user="&user"
        optionsx="&_options";

    data work._crud_result;
        length test $32 status $8 message $500;
        test='DELETE_FOLDER';
        did=dopen('sftproot');

        if did>0 then do;
            rc=ddelete("%superq(test_folder)",did);

            if rc=0 then do;
                status='PASS';
                message='Test folder deleted.';
            end;
            else do;
                status='FAIL';
                message=sysmsg();
            end;

            rc_close=dclose(did);
        end;
        else do;
            status='FAIL';
            message=sysmsg();
        end;

        output;
    run;

    proc append base=&out data=work._crud_result force; run;
    filename sftproot clear;

    proc datasets library=work nolist;
        delete _crud_result;
    quit;

    proc print data=&out noobs;
        title 'SFTP CRUD Test Results';
    run;
    title;
%mend sftp_test_crud;


/*
Example:

%sftp_test_crud(
    host=example.com,
    user=myuser,
    test_root=/test/sas-transfer,
    keyfile=C:\keys\id_rsa
);
*/
