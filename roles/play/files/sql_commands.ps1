$var_folder = $args[0]
$var_file = $args[1]
$var_sql_user = $args[2]
$var_sql_pass = $args[3]

Invoke-Sqlcmd -Username $var_sql_user -Password $var_sql_pass -InputFile "$var_folder\$var_file"
