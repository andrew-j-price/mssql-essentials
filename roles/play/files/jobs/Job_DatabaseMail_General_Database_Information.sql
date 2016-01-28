USE [msdb]
GO

IF EXISTS (SELECT job_id FROM msdb.dbo.sysjobs_view WHERE name = N'DatabaseMail - General Database Information')
EXEC msdb.dbo.sp_delete_job @job_name=N'DatabaseMail - General Database Information', @delete_unused_schedule=1
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
EXEC @ReturnCode =  msdb.dbo.sp_add_job @job_name=N'DatabaseMail - General Database Information', 
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

EXEC @ReturnCode = msdb.dbo.sp_add_jobstep @job_id=@jobId, @step_name=N'General Database Informaiton', 
		@step_id=1, 
		@cmdexec_success_code=0, 
		@on_success_action=1, 
		@on_success_step_id=0, 
		@on_fail_action=2, 
		@on_fail_step_id=0, 
		@retry_attempts=0, 
		@retry_interval=0, 
		@os_run_priority=0, @subsystem=N'TSQL', 
		@command=N'-- Start T-SQL --
IF 
(SELECT is_local 
FROM sys.dm_hadr_availability_replica_states
WHERE role_desc = ''PRIMARY'' ) = 1
BEGIN
	PRINT ''Primary''

DECLARE @QueryToRun NVARCHAR(MAX) 
SET @QueryToRun = ''
SET NOCOUNT ON
SELECT
GI.DatabaseName AS [Database Name],
GI.Status,
GI.[Recovery Model],
GI.[Logical Name],
GI.[File Type],
--GI.[Size Allocated (MB)],
GI.[Size Allocated (GB)],
FD.UsedSpaceGB AS [Used Space (GB)],
FD.FreeSpaceGB AS [Free Space (GB)],
GI.[Max File Size],
GI.[Growth] AS [Auto Grow By],
GI.[File Path]
FROM ##DatabaseFileDetails AS FD
INNER JOIN ##DatabaseGeneralInfo AS GI
ON FD.DatabaseName = GI.DatabaseName 
AND FD.FileID = GI.FileID
WHERE GI.database_id > 4
ORDER BY [Database Name],[File Type],[Logical Name]
''

IF OBJECT_ID (''tempdb..##DatabaseGeneralInfo'') IS NOT NULL
	DROP TABLE ##DatabaseGeneralInfo;
IF OBJECT_ID (''tempdb..##DatabaseFileDetails'') IS NOT NULL
	DROP TABLE ##DatabaseFileDetails;

BEGIN
	SELECT
	DB.Name AS [DatabaseName],
	MF.database_id,
	MF.file_id AS FileId,
	DB.state_desc AS [Status],
	DB.recovery_model_desc AS [Recovery Model],
	MF.name AS [Logical Name],
	--MF.type_desc AS [UglyType],
	CASE MF.type_desc 
		WHEN ''ROWS'' THEN ''Data''
		WHEN ''LOG'' THEN ''Log''
		WHEN ''FILESTREAM'' THEN ''FileStream''
		WHEN ''FULLTEXT'' THEN ''FullText''
		ELSE ''Other''
		END AS [File Type],
	CONVERT(DECIMAL(20,0),(MF.size * 8) / 1024) AS [Size Allocated (MB)],
	CONVERT(DECIMAL(20,1),(MF.size * 8.00) / 1024.00 / 1024.00) AS [Size Allocated (GB)],
	CASE WHEN MF.[max_size]=-1 THEN ''Unlimited'' ELSE CONVERT(VARCHAR(10),CONVERT(bigint,MF.[max_size])*8/1024/1024) +'' GB'' END AS [Max File Size],
	CASE MF.is_percent_growth WHEN 1 THEN CONVERT(VARCHAR(10),MF.growth) +''%'' ELSE Convert(VARCHAR(10),MF.growth*8/1024) +'' MB'' END AS [Growth],
	MF.physical_name AS [File Path]
	INTO	##DatabaseGeneralInfo
	FROM sys.databases AS DB
	INNER JOIN sys.master_files AS MF 
	ON DB.database_id = MF.database_id 
	WHERE HAS_DBACCESS(DB.name) = 1 
	--AND MF.database_id > 4
	ORDER BY [DatabaseName],[File Type],[Logical Name]
END
	
EXECUTE sp_msforeachdb N''USE [?]
	IF OBJECT_ID (''''tempdb..##DatabaseFileDetails'''') IS NULL
		BEGIN
			SELECT	DB_NAME() AS DatabaseName,
				[file_id] AS FileId,
				[name] AS [FileName],
				CAST((([size]*8/1024.0)/1024.0) AS DECIMAL(18,2)) AS FileSizeGB,
				CAST((((FILEPROPERTY([name],''''spaceused'''')*8)/1024.0)/1024.0) AS DECIMAL(18,2)) AS UsedSpaceGB,
				CAST(((((size - FILEPROPERTY([name],''''spaceused''''))*8)/1024.0)/1024.0) AS DECIMAL(18,2)) AS FreeSpaceGB
			INTO	##DatabaseFileDetails
			FROM	sys.database_files
		END
	ELSE
			INSERT INTO ##DatabaseFileDetails
			SELECT	DB_NAME() AS DatabaseName,
			[file_id] AS FileId,
			[name] AS [FileName],
			CAST((([size]*8/1024.0)/1024.0) AS DECIMAL(18,2)) AS FileSizeGB,
			CAST((((FILEPROPERTY([name],''''spaceused'''')*8)/1024.0)/1024.0) AS DECIMAL(18,2)) AS UsedSpaceGB,
			CAST(((((size - FILEPROPERTY([name],''''spaceused''''))*8)/1024.0)/1024.0) AS DECIMAL(18,2)) AS FreeSpaceGB
			FROM	sys.database_files''
		

DECLARE @ReturnedRecords INT
EXEC sp_executesql @QueryToRun
SELECT @ReturnedRecords = @@ROWCOUNT
PRINT @ReturnedRecords

IF @ReturnedRecords > 0
BEGIN
	USE [msdb]
	
	DECLARE @EmailBody NVARCHAR(MAX);
	SET @EmailBody = @@SERVERNAME + '' generated the attached output.'' 
    	
	DECLARE @OperatorEmail NVARCHAR(100);
	SET @OperatorEmail = (SELECT email_address
	FROM msdb.dbo.sysoperators
	WHERE name = ''DBA'');
		    	
    EXEC sp_send_dbmail
		@profile_name =''DatabaseMailProfile'',
		@recipients =@OperatorEmail,
		@subject =''General SQL Database Information'',
		@body_format=''HTML'',
		@body = @EmailBody,
		@execute_query_database =''msdb'',
		@query = @QueryToRun,
		@attach_query_result_as_file = 1,
		@query_attachment_filename=''output.csv'',
		@query_result_width=32767,
		@query_result_separator=''	'',
		@query_result_no_padding=1
END
ELSE
	PRINT ''No records to send''

IF OBJECT_ID (''tempdb..##DatabaseGeneralInfo'') IS NOT NULL
	DROP TABLE ##DatabaseGeneralInfo;
IF OBJECT_ID (''tempdb..##DatabaseFileDetails'') IS NOT NULL
	DROP TABLE ##DatabaseFileDetails;

END
ELSE PRINT ''Secondary'' ;
GO
-- End T-SQL --', 
		@database_name=N'msdb', 
		@flags=0
IF (@@ERROR <> 0 OR @ReturnCode <> 0) GOTO QuitWithRollback
EXEC @ReturnCode = msdb.dbo.sp_update_job @job_id = @jobId, @start_step_id = 1
IF (@@ERROR <> 0 OR @ReturnCode <> 0) GOTO QuitWithRollback
EXEC @ReturnCode = msdb.dbo.sp_add_jobschedule @job_id=@jobId, @name=N'Maintenance - Weekly on Sunday at 12:30 AM', 
		@enabled=0, 
		@freq_type=8, 
		@freq_interval=1, 
		@freq_subday_type=1, 
		@freq_subday_interval=0, 
		@freq_relative_interval=0, 
		@freq_recurrence_factor=1, 
		@active_start_date=20140501, 
		@active_end_date=99991231, 
		@active_start_time=3000, 
		@active_end_time=235959, 
		@schedule_uid=N'b1920478-9f02-4339-8b35-2d2b47034df5'
IF (@@ERROR <> 0 OR @ReturnCode <> 0) GOTO QuitWithRollback
EXEC @ReturnCode = msdb.dbo.sp_add_jobserver @job_id = @jobId, @server_name = N'(local)'
IF (@@ERROR <> 0 OR @ReturnCode <> 0) GOTO QuitWithRollback
COMMIT TRANSACTION
GOTO EndSave
QuitWithRollback:
    IF (@@TRANCOUNT > 0) ROLLBACK TRANSACTION
EndSave:

GO


