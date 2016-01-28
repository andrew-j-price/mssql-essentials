USE [msdb]
GO

IF EXISTS (SELECT job_id FROM msdb.dbo.sysjobs_view WHERE name = N'DatabaseMail - Index Fragmentation')
EXEC msdb.dbo.sp_delete_job @job_name=N'DatabaseMail - Index Fragmentation', @delete_unused_schedule=1
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
EXEC @ReturnCode =  msdb.dbo.sp_add_job @job_name=N'DatabaseMail - Index Fragmentation', 
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

EXEC @ReturnCode = msdb.dbo.sp_add_jobstep @job_id=@jobId, @step_name=N'DatabaseMail - Index Fragmentation', 
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
--Review Results and Messages tabs for validating output in SSMS

IF 
(SELECT is_local 
FROM sys.dm_hadr_availability_replica_states
WHERE role_desc = ''PRIMARY'' ) = 1
BEGIN
	PRINT ''Primary''

DECLARE @QueryCreateTable NVARCHAR(MAX)
DECLARE @QueryToRun NVARCHAR(MAX)
DECLARE @QueryDropTable NVARCHAR(MAX)

SET @QueryCreateTable = ''
CREATE TABLE ##DatabaseIndexFragmentation
(
DatabaseName varchar(100),
SchemaName varchar(100),
ObjectName varchar(100),
IndexName varchar(100),
Avg_Fragmentation_In_Percent float,
IndexType varchar(100),
PartitionNumber int,
--IndexID int, 
--IndexLevel int,
PageCount int
) 
''

SET @QueryDropTable = ''
DROP TABLE ##DatabaseIndexFragmentation
''

IF OBJECT_ID(N''tempdb..##DatabaseIndexFragmentation'', ''U'') IS NOT NULL EXECUTE sp_executesql @QueryDropTable --DROP TABLE ##TempTableName
EXECUTE sp_executesql @QueryCreateTable

INSERT INTO ##DatabaseIndexFragmentation (DatabaseName,SchemaName,ObjectName,IndexName,Avg_Fragmentation_In_Percent,IndexType,PartitionNumber,[PageCount]) 
exec master.sys.sp_MSforeachdb '' USE [?] 
IF DB_ID(''''?'''') > 4
SELECT db_name() AS DatabaseName, 
SCHEMA_NAME (ao.schema_id) AS SchemaName,
OBJECT_NAME (ps.object_id) AS ObjectName,  
si.name AS IndexName, 
ps.avg_fragmentation_in_percent AS Avg_Fragmentation_In_Percent, 
ps.index_type_desc,
ps.partition_number AS PartitionNumber,
--ps.index_id AS IndexID,
--ps.index_level AS IndexLevel,
ps.page_count AS PageCount
FROM sys.dm_db_index_physical_stats (DB_ID(), NULL, NULL, NULL, NULL) AS ps
JOIN sys.indexes AS si
ON ps.object_id = si.object_id 
AND ps.index_id = si.index_id 
INNER JOIN sys.all_objects ao 
ON ps.[object_id] = ao.[object_id]
WHERE si.index_id <> 0 
AND page_count > 1000
AND ps.avg_fragmentation_in_percent <> 0
AND HAS_DBACCESS(db_name()) = 1 
'' 

SET @QueryToRun = ''
SET NOCOUNT ON
PRINT @@SERVERNAME
PRINT '''' ''''
PRINT ''''Sorted by most fragmented indexes''''
SELECT * FROM ##DatabaseIndexFragmentation
ORDER BY Avg_Fragmentation_In_Percent DESC

PRINT '''' ''''
PRINT '''' ''''
PRINT ''''Sorted by db-schema-object-index''''
SELECT * FROM ##DatabaseIndexFragmentation
ORDER BY DatabaseName, SchemaName, ObjectName, IndexName, PartitionNumber
''

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
		@subject =''Database Index Fragementation'',
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

EXECUTE sp_executesql @QueryDropTable

END
ELSE PRINT ''Secondary'' ;
GO
-- End T-SQL --', 
		@database_name=N'master', 
		@flags=0
IF (@@ERROR <> 0 OR @ReturnCode <> 0) GOTO QuitWithRollback
EXEC @ReturnCode = msdb.dbo.sp_update_job @job_id = @jobId, @start_step_id = 1
IF (@@ERROR <> 0 OR @ReturnCode <> 0) GOTO QuitWithRollback
EXEC @ReturnCode = msdb.dbo.sp_add_jobschedule @job_id=@jobId, @name=N'Maintenance - Weekly on Friday and Sunday at 4:15 AM', 
		@enabled=0, 
		@freq_type=8, 
		@freq_interval=33, 
		@freq_subday_type=1, 
		@freq_subday_interval=0, 
		@freq_relative_interval=0, 
		@freq_recurrence_factor=1, 
		@active_start_date=20140501, 
		@active_end_date=99991231, 
		@active_start_time=41500, 
		@active_end_time=235959, 
		@schedule_uid=N'4ce3d914-63e5-4076-b895-cde0d26ce745'
IF (@@ERROR <> 0 OR @ReturnCode <> 0) GOTO QuitWithRollback
EXEC @ReturnCode = msdb.dbo.sp_add_jobserver @job_id = @jobId, @server_name = N'(local)'
IF (@@ERROR <> 0 OR @ReturnCode <> 0) GOTO QuitWithRollback
COMMIT TRANSACTION
GOTO EndSave
QuitWithRollback:
    IF (@@TRANCOUNT > 0) ROLLBACK TRANSACTION
EndSave:

GO


