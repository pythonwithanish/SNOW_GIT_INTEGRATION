CREATE TABLE IF NOT EXISTS _SNOW_DB_.SNOW_GIT_INT_SCH.DEPLOYMENT_LOG (
    LOG_ID              NUMBER AUTOINCREMENT PRIMARY KEY,
    REQUEST_ID          VARCHAR(100),        -- SR or CR number, free text for now
    SCRIPT_NAME         VARCHAR(500),        -- file name / path from stage
    EXECUTED_BY         VARCHAR(100)  DEFAULT CURRENT_USER(),
    EXECUTED_AT         TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP(),
    ROLE_AT_EXECUTION   VARCHAR(100)  DEFAULT CURRENT_ROLE(),
    RAW_SCRIPT          VARCHAR,             -- original script before substitution
    RESOLVED_SCRIPT     VARCHAR,             -- script after token replacement
    STATUS              VARCHAR(10),         -- 'SUCCESS' or 'FAILED'
    ERROR_MESSAGE       VARCHAR,             -- NULL if SUCCESS
    EXECUTION_MS        NUMBER,              -- duration in milliseconds
    UNRESOLVED_TOKENS   VARCHAR             -- populated if tokens were found but not replaced
);