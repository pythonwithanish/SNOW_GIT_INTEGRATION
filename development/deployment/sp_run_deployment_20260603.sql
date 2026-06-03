
--call _SNOW_DB_.SNOW_GIT_INT_SCH.SP_RUN_DEPLOYMENT(1,'development/Extract/ddl_CUSTOMER_EX.sql');

CREATE OR REPLACE PROCEDURE _SNOW_DB_.SNOW_GIT_INT_SCH.SP_RUN_DEPLOYMENT(
    REQUEST_ID  VARCHAR,
    SCRIPT_NAME VARCHAR
)
RETURNS VARCHAR
LANGUAGE SQL
EXECUTE AS CALLER
AS
$$
DECLARE
    -- Script content
    v_raw_script        VARCHAR;
    v_resolved_script   VARCHAR;
    v_read_sql          VARCHAR;

    -- Token substitution
    v_token             VARCHAR;
    v_value             VARCHAR;

    -- Execution tracking
    v_start             TIMESTAMP_NTZ;
    v_end               TIMESTAMP_NTZ;
    v_exec_ms           NUMBER;
    v_unresolved        VARCHAR;

    -- Statement splitting
    v_statements        ARRAY;
    v_stmt              VARCHAR;
    v_stmt_count        NUMBER;
    v_index             NUMBER;

    -- Cursor over token registry
    c_tokens CURSOR FOR
        SELECT 
            TRIM(PARAMETER_NAME)  AS TOKEN,
            TRIM(PARAMETER_VALUE) AS TOKEN_VALUE
        FROM _SNOW_DB_.SNOW_GIT_INT_SCH.DEPLOYMENT_PARAMETER_VALUES
        WHERE PARAMETER_NAME IS NOT NULL
          AND PARAMETER_VALUE IS NOT NULL;

BEGIN
    ------------------------------------------------------------
    -- STEP 1: Read raw script from Git stage
    ------------------------------------------------------------
    BEGIN
        v_read_sql := 'SELECT LISTAGG($1, '' '') AS FILE_CONTENT FROM @_SNOW_DB_.SNOW_GIT_INT_SCH.SNOW_GIT_INT_REPO/branches/main/'
                      || SCRIPT_NAME
                      || ' (FILE_FORMAT => ''_SNOW_DB_.SNOW_GIT_INT_SCH.MY_TEXT_FORMAT'')';

        LET res RESULTSET := (EXECUTE IMMEDIATE :v_read_sql);
        LET cur CURSOR FOR res;
        OPEN cur;
        FETCH cur INTO v_raw_script;
        CLOSE cur;
    EXCEPTION
        WHEN OTHER THEN
            INSERT INTO _SNOW_DB_.SNOW_GIT_INT_SCH.DEPLOYMENT_LOG (
                REQUEST_ID, SCRIPT_NAME, STATUS, ERROR_MESSAGE
            ) VALUES (
                :REQUEST_ID,
                :SCRIPT_NAME,
                'FAILED',
                'Could not read script from stage. Check path and stage access. Error: ' || :sqlerrm
            );
            RETURN 'FAILED: Could not read script — ' || :sqlerrm;
    END;

    -- NULL guard
    IF (v_raw_script IS NULL OR LENGTH(TRIM(v_raw_script)) = 0) THEN
        INSERT INTO _SNOW_DB_.SNOW_GIT_INT_SCH.DEPLOYMENT_LOG (
            REQUEST_ID, SCRIPT_NAME, STATUS, ERROR_MESSAGE
        ) VALUES (
            :REQUEST_ID, :SCRIPT_NAME,
            'FAILED',
            'Script was read but returned NULL or empty. Check file format and stage path.'
        );
        RETURN 'FAILED: Script content is NULL or empty';
    END IF;

    -- Carry raw script forward for logging
    v_resolved_script := v_raw_script;

    -- TEMPORARY DEBUG — remove once confirmed working
    --RETURN 'DEBUG: ' || v_resolved_script;

    ------------------------------------------------------------
    -- STEP 2: Dynamically substitute all tokens from parameter table
    ------------------------------------------------------------
    FOR rec IN c_tokens DO
        v_resolved_script := REPLACE(v_resolved_script, rec.TOKEN, rec.TOKEN_VALUE);
    END FOR;

    ------------------------------------------------------------
    -- STEP 3: Detect any unresolved tokens (pattern __ ... __)
    ------------------------------------------------------------
    v_unresolved := NULL;

    SELECT LISTAGG(DISTINCT matched_token, ', ')
    INTO   :v_unresolved
    FROM (
        SELECT REGEXP_SUBSTR(
                    :v_resolved_script,
                    '__[A-Z0-9_]+__',
                    1,
                    seq4() + 1
               ) AS matched_token
        FROM TABLE(GENERATOR(ROWCOUNT => 1000))
    )
    WHERE matched_token IS NOT NULL;

    IF (v_unresolved IS NOT NULL AND LENGTH(TRIM(v_unresolved)) > 0) THEN
        INSERT INTO _SNOW_DB_.SNOW_GIT_INT_SCH.DEPLOYMENT_LOG (
            REQUEST_ID, SCRIPT_NAME, RAW_SCRIPT, RESOLVED_SCRIPT,
            STATUS, ERROR_MESSAGE, UNRESOLVED_TOKENS
        ) VALUES (
            :REQUEST_ID, :SCRIPT_NAME, :v_raw_script, :v_resolved_script,
            'FAILED',
            'Deployment aborted. Unresolved tokens found. Add them to DEPLOYMENT_PARAMETER_VALUES.',
            :v_unresolved
        );
        RETURN 'FAILED: Unresolved tokens — ' || v_unresolved;
    END IF;

    ------------------------------------------------------------
    -- STEP 4: Split on semicolon and execute each statement
    ------------------------------------------------------------
    v_start      := CURRENT_TIMESTAMP();
    v_statements := SPLIT(v_resolved_script, ';');
    v_stmt_count := ARRAY_SIZE(v_statements);
    v_index      := 0;

    WHILE (v_index < v_stmt_count) DO
        v_stmt := TRIM(GET(v_statements, v_index)::VARCHAR);

        IF (LENGTH(v_stmt) > 0) THEN
            EXECUTE IMMEDIATE :v_stmt;
        END IF;

        v_index := v_index + 1;
    END WHILE;

    v_end     := CURRENT_TIMESTAMP();
    v_exec_ms := DATEDIFF('millisecond', v_start, v_end);

    ------------------------------------------------------------
    -- STEP 5: Log success
    ------------------------------------------------------------
    INSERT INTO _SNOW_DB_.SNOW_GIT_INT_SCH.DEPLOYMENT_LOG (
        REQUEST_ID, SCRIPT_NAME, RAW_SCRIPT, RESOLVED_SCRIPT,
        STATUS, EXECUTION_MS
    ) VALUES (
        :REQUEST_ID, :SCRIPT_NAME, :v_raw_script, :v_resolved_script,
        'SUCCESS', :v_exec_ms
    );

    RETURN 'SUCCESS: ' || SCRIPT_NAME || ' deployed in ' || v_exec_ms || 'ms';

EXCEPTION
    WHEN OTHER THEN
        v_end     := CURRENT_TIMESTAMP();
        v_exec_ms := DATEDIFF('millisecond', v_start, v_end);

        INSERT INTO _SNOW_DB_.SNOW_GIT_INT_SCH.DEPLOYMENT_LOG (
            REQUEST_ID, SCRIPT_NAME, RAW_SCRIPT, RESOLVED_SCRIPT,
            STATUS, ERROR_MESSAGE, EXECUTION_MS
        ) VALUES (
            :REQUEST_ID, :SCRIPT_NAME, :v_raw_script, :v_resolved_script,
            'FAILED', :sqlerrm, :v_exec_ms
        );

        RETURN 'FAILED: ' || :sqlerrm;
END;
$$;