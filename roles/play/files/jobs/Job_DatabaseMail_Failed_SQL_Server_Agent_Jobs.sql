USE [msdb]
GO

IF EXISTS (SELECT job_id FROM msdb.dbo.sysjobs_view WHERE name = N'DatabaseMail - Failed SQL Server Agent Jobs')
EXEC msdb.dbo.sp_delete_job @job_name=N'DatabaseMail - Failed SQL Server Agent Jobs', @delete_unused_schedule=1
GO


BEGIN TRANSACTION
DECLARE @ReturnCode INT
SELECT @ReturnCode = 0

IF NOT EXISTS (SELECT name FROM msdb.dbo.syscategories WHERE name=N'Database Mail' AND category_class=1)
BEGIN
EXEC @ReturnCode = msdb.dbo.sp_add_category @class=N'JOB', @type=N'LOCAL', @name=N'Database Mail'
IF (@@ERROR <> 0 OR @ReturnCode <> 0) GOTO QuitWithRollback

END

DECLARE @jobId BINARY(16)
EXEC @ReturnCode =  msdb.dbo.sp_add_job @job_name=N'DatabaseMail - Failed SQL Server Agent Jobs', 
		@enabled=1, 
		@notify_level_eventlog=2, 
		@notify_level_email=2, 
		@notify_level_netsend=0, 
		@notify_level_page=0, 
		@delete_level=0, 
		@description=N'No description available.', 
		@category_name=N'Database Mail', 
		@owner_login_name=N'sa', 
		@notify_email_operator_name=N'DBA', @job_id = @jobId OUTPUT
IF (@@ERROR <> 0 OR @ReturnCode <> 0) GOTO QuitWithRollback

EXEC @ReturnCode = msdb.dbo.sp_add_jobstep @job_id=@jobId, @step_name=N'Check SQL Server Agent History', 
		@step_id=1, 
		@cmdexec_success_code=0, 
		@on_success_action=1, 
		@on_success_step_id=0, 
		@on_fail_action=2, 
		@on_fail_step_id=0, 
		@retry_attempts=0, 
		@retry_interval=0, 
		@os_run_priority=0, @subsystem=N'TSQL', 
		@command=N'--DatabaseMail - Failed SQL Server Agent Jobs in the past day
-- Start T-SQL --
--Review Results and Messages tabs for validating output in SSMS
DECLARE @QueryCreateTable NVARCHAR(MAX)
DECLARE @QueryInsertData NVARCHAR(MAX)
DECLARE @QueryToRun NVARCHAR(MAX)
DECLARE @QueryDropTable NVARCHAR(MAX)

SET @QueryCreateTable = ''
CREATE TABLE ##SQLJobErrors
(
ServerName VARCHAR(100),
FailureDate VARCHAR(100),
RunTime VARCHAR(100),
JobName VARCHAR(100),
Step_id VARCHAR(100),
StepName VARCHAR(100),
ErrorMessage VARCHAR(500)
)''

SET @QueryInsertData = ''
INSERT INTO ##SQLJobErrors
SELECT DISTINCT
T1.server AS [ServerName],
CONVERT(CHAR(10), CAST(STR(run_date,8, 0) AS DateTime), 111) AS [FailureDate],
CAST(STUFF(STUFF(REPLACE(STR(run_time, 6), '''' '''', ''''0''''), 3, 0, '''':''''), 6, 0, '''':'''') AS Time(0)) AS [RunTime],
T2.name AS [JobName],
T1.step_id AS [Step_id],
T1.step_name AS [StepName],
LEFT(T1.[message],500) AS [ErrorMessage]
FROM msdb..sysjobhistory T1
JOIN msdb..sysjobs T2
ON T1.job_id = T2.job_id
WHERE T1.run_status NOT IN (1,4) --Where is Failed and not Succeeded, Retry, or Canceled
--AND T1.step_id != 0 --Use for Step Outcome
--AND T1.step_id = 0 --Use for overall "Job Outcome"
AND run_date >= CONVERT(char(8), (select dateadd (day,(-1), getdate())), 112) --Past X days, in "112" yymmdd format)ent <>0
''

SET @QueryToRun = ''
SELECT *
FROM ##SQLJobErrors
''

SET @QueryDropTable = ''
DROP TABLE ##SQLJobErrors
''

IF OBJECT_ID(N''tempdb..##SQLJobErrors'', ''U'') IS NOT NULL EXECUTE sp_executesql @QueryDropTable
EXECUTE sp_executesql @QueryCreateTable
EXECUTE sp_executesql @QueryInsertData
EXECUTE sp_executesql @QueryToRun

DECLARE @RecordCount INT
SET @RecordCount = @@ROWCOUNT
SELECT @RecordCount AS RecordsReturned

IF @RecordCount > 0
BEGIN
	USE msdb
	
	DECLARE @EmailTable NVARCHAR(MAX)
	SET @EmailTable = CAST( (
	SELECT td = CAST( ColumnA AS VARCHAR(100)) + ''</td><td>'' + CAST( ColumnB AS VARCHAR(100) ) + ''</td><td>'' + CAST( ColumnC AS VARCHAR(100) ) + ''</td><td>'' + CAST( ColumnD AS VARCHAR(100) ) + ''</td><td>'' + CAST( ColumnE AS VARCHAR(100) ) + ''</td><td>'' + CAST( ColumnF AS VARCHAR(100) ) + ''</td><td>'' + CAST( ColumnG AS VARCHAR(500) )
	FROM (
		SELECT DISTINCT TOP (1000) ColumnA  = ServerName,
			ColumnB = FailureDate,
			ColumnC = RunTime,
			ColumnD = JobName,
			ColumnE = Step_id,
			ColumnF = StepName,
			ColumnG = ErrorMessage
		FROM ##SQLJobErrors
		) AS d
	FOR XML PATH( ''tr'' ), TYPE ) AS VARCHAR(MAX) )

	SET @EmailTable = ''<table cellpadding="2" cellspacing="2" border="1">''
			  + ''<tr><th>Server Name</th><th>Failure Date</th><th>Run Time</th><th>Job Name</th><th>Step ID</th><th>Step Name</th><th>Error Message</th></tr>''
			  + replace( replace( @EmailTable, ''&lt;'', ''<'' ), ''&gt;'', ''>'' )
			  + ''</table>''
	--PRINT @EmailTable
	
	DECLARE @EmailBody NVARCHAR(MAX);
	SET @EmailBody = @@SERVERNAME + '' generated the output below.'' + ''<br><br>'' + @EmailTable
	
	DECLARE @OperatorEmail NVARCHAR(100);
	SET @OperatorEmail = (SELECT email_address
	FROM msdb.dbo.sysoperators
	WHERE name = ''DBA'');
		    	
    EXEC sp_send_dbmail
		@profile_name =''DatabaseMailProfile'',
		@recipients =@OperatorEmail,
		@subject =''Failed SQL Server Agent Jobs for past 24 hours'',
		@body_format=''HTML'',
		@body = @EmailBody,
		@execute_query_database =''msdb''
END
ELSE
	Print ''No records to send''

EXECUTE sp_executesql @QueryDropTable
-- End T-SQL --', 
		@database_name=N'msdb', 
		@flags=0
IF (@@ERROR <> 0 OR @ReturnCode <> 0) GOTO QuitWithRollback
EXEC @ReturnCode = msdb.dbo.sp_update_job @job_id = @jobId, @start_step_id = 1
IF (@@ERROR <> 0 OR @ReturnCode <> 0) GOTO QuitWithRollback
EXEC @ReturnCode = msdb.dbo.sp_add_jobschedule @job_id=@jobId, @name=N'Maintenance - Daily at 5:55 AM', 
		@enabled=0, 
		@freq_type=4, 
		@freq_interval=1, 
		@freq_subday_type=1, 
		@freq_subday_interval=0, 
		@freq_relative_interval=0, 
		@freq_recurrence_factor=0, 
		@active_start_date=20140501, 
		@active_end_date=99991231, 
		@active_start_time=55500, 
		@active_end_time=235959, 
		@schedule_uid=N'0d9ea70d-5bd6-45be-9fcd-fe7b25c4de4d'
IF (@@ERROR <> 0 OR @ReturnCode <> 0) GOTO QuitWithRollback
EXEC @ReturnCode = msdb.dbo.sp_add_jobserver @job_id = @jobId, @server_name = N'(local)'
IF (@@ERROR <> 0 OR @ReturnCode <> 0) GOTO QuitWithRollback
COMMIT TRANSACTION
GOTO EndSave
QuitWithRollback:
    IF (@@TRANCOUNT > 0) ROLLBACK TRANSACTION
EndSave:

GO


