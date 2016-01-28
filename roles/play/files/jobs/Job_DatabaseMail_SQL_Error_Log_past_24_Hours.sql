USE [msdb]
GO

IF EXISTS (SELECT job_id FROM msdb.dbo.sysjobs_view WHERE name = N'DatabaseMail - SQL Error Log past 24 Hours')
EXEC msdb.dbo.sp_delete_job @job_name=N'DatabaseMail - SQL Error Log past 24 Hours', @delete_unused_schedule=1
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
EXEC @ReturnCode =  msdb.dbo.sp_add_job @job_name=N'DatabaseMail - SQL Error Log past 24 Hours', 
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

EXEC @ReturnCode = msdb.dbo.sp_add_jobstep @job_id=@jobId, @step_name=N'Check Logs', 
		@step_id=1, 
		@cmdexec_success_code=0, 
		@on_success_action=1, 
		@on_success_step_id=0, 
		@on_fail_action=2, 
		@on_fail_step_id=0, 
		@retry_attempts=0, 
		@retry_interval=0, 
		@os_run_priority=0, @subsystem=N'TSQL', 
		@command=N'--SQL Error Logs via HTML output for Past 24 Hours
-- Start T-SQL --
--Review Results and Messages tabs for validating output in SSMS
DECLARE @QueryCreateTable NVARCHAR(MAX)
DECLARE @QueryInsertData NVARCHAR(MAX)
DECLARE @QueryToRun NVARCHAR(MAX)
DECLARE @QueryDropTable NVARCHAR(MAX)

SET @QueryCreateTable = ''
CREATE TABLE ##SQLErrorLog
(
LogDate DATETIME,
ProcessInfo VARCHAR(20),
Text VARCHAR(800)
)''

SET @QueryInsertData = ''
INSERT INTO ##SQLErrorLog
EXEC xp_readerrorlog 0
''

SET @QueryToRun = ''
SET NOCOUNT ON
--PRINT @@SERVERNAME
--PRINT '''' ''''
SELECT * FROM ##SQLErrorLog
WHERE LogDate >= dateadd(hh,-24,getdate())
AND Text NOT LIKE ''''Database backed up%''''
AND Text NOT LIKE ''''Log was backed up%''''
AND Text NOT LIKE ''''Database differential changes were backed up%''''
AND Text NOT LIKE ''''BACKUP DATABASE successfully processed%''''
AND Text NOT LIKE ''''BACKUP DATABASE WITH DIFFERENTIAL successfully processed%''''
--AND Text NOT LIKE ''''Using %dbghelp.dll% version%'''' --KB2878139
AND Text NOT LIKE ''''The Service Broker endpoint is in disabled or stopped state.''''
AND Text NOT LIKE ''''This instance of SQL Server has been using a process ID of%''''
AND Text NOT LIKE ''''DBCC CHECKDB % found 0 errors %''''
ORDER BY LogDate ASC
''

SET @QueryDropTable = ''
DROP TABLE ##SQLErrorLog
''

IF OBJECT_ID(N''tempdb..##SQLErrorLog'', ''U'') IS NOT NULL EXECUTE sp_executesql @QueryDropTable --DROP TABLE ##SQLErrorLog
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
	SELECT td = CAST( ColumnA AS VARCHAR(30)) + ''</td><td>'' + CAST( ColumnB AS VARCHAR(30) ) + ''</td><td>'' + CAST( ColumnC AS VARCHAR(1024) )
	FROM (
		SELECT TOP (1000) ColumnA  = LogDate,
			ColumnB = ProcessInfo,
			ColumnC = Text
		FROM ##SQLErrorLog
		WHERE LogDate >= dateadd(hh,-24,getdate())
			AND Text NOT LIKE ''Database backed up%''
			AND Text NOT LIKE ''Log was backed up%''
			AND Text NOT LIKE ''Database differential changes were backed up%''
			AND Text NOT LIKE ''BACKUP DATABASE successfully processed%''
			AND Text NOT LIKE ''BACKUP DATABASE WITH DIFFERENTIAL successfully processed%''
			AND Text NOT LIKE ''The Service Broker endpoint is in disabled or stopped state.''
			AND Text NOT LIKE ''This instance of SQL Server has been using a process ID of%''
			AND Text NOT LIKE ''DBCC CHECKDB % found 0 errors %''
		ORDER BY LogDate ASC
		) AS d
	FOR XML PATH( ''tr'' ), TYPE ) AS VARCHAR(MAX) )

	SET @EmailTable = ''<table cellpadding="2" cellspacing="2" border="1">''
			  + ''<tr><th>Log Date</th><th>Process Info</th><th>Text</th></tr>''
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
		@subject =''SQL Error Logs for past 24 hours'',
		@body_format=''HTML'',
		@body = @EmailBody,
		@execute_query_database =''msdb''
END
ELSE
	PRINT ''No records to send''

EXECUTE sp_executesql @QueryDropTable
-- End T-SQL --', 
		@database_name=N'master', 
		@flags=0
IF (@@ERROR <> 0 OR @ReturnCode <> 0) GOTO QuitWithRollback
EXEC @ReturnCode = msdb.dbo.sp_update_job @job_id = @jobId, @start_step_id = 1
IF (@@ERROR <> 0 OR @ReturnCode <> 0) GOTO QuitWithRollback
EXEC @ReturnCode = msdb.dbo.sp_add_jobschedule @job_id=@jobId, @name=N'Maintenance - Daily at 6:00 AM', 
		@enabled=0, 
		@freq_type=4, 
		@freq_interval=1, 
		@freq_subday_type=1, 
		@freq_subday_interval=0, 
		@freq_relative_interval=0, 
		@freq_recurrence_factor=0, 
		@active_start_date=20140501, 
		@active_end_date=99991231, 
		@active_start_time=60000, 
		@active_end_time=235959, 
		@schedule_uid=N'216793ec-511f-45b6-9b4c-582dae3cddab'
IF (@@ERROR <> 0 OR @ReturnCode <> 0) GOTO QuitWithRollback
EXEC @ReturnCode = msdb.dbo.sp_add_jobserver @job_id = @jobId, @server_name = N'(local)'
IF (@@ERROR <> 0 OR @ReturnCode <> 0) GOTO QuitWithRollback
COMMIT TRANSACTION
GOTO EndSave
QuitWithRollback:
    IF (@@TRANCOUNT > 0) ROLLBACK TRANSACTION
EndSave:

GO


