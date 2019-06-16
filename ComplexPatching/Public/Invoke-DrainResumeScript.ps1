param
(
    [parameter(Mandatory = $true)]
    [string]$ComputerName,
    # Provides the computer name to start

    [parameter(Mandatory = $true)]
    [string]$DryRun,
    # skips patching check so that we can perform a dry run of the drain an resume

    [parameter(Mandatory = $true)]
    [ValidateSet('DrainScript', 'ResumeScript')]
    [string]$ScriptType,
    # Provides the type of script to query for in the DB and run

    [parameter(Mandatory = $true)]
    [int32]$RBInstance,
    # RBInstance which represents the Runbook Process ID for this runbook workflow

    [parameter(Mandatory = $true)]
    [string]$SQLServer,
    # Database server for staging information during the patching process

    [parameter(Mandatory = $true)]
    [string]$OrchStagingDB,
    # Database for staging information during the patching process

    [parameter(Mandatory = $true)]
    [string]$LogLocation
    # UNC path to store log files in
)

#region import modules
Import-Module -Name ComplexPatching
#endregion import modules

#-----------------------------------------------------------------------

## Initialize result and trace variables
# $ResultStatus provides basic success/failed indicator
# $ErrorMessage captures any error text generated by script
# $Trace is used to record a running log of actions
[bool]$DryRun = ConvertTo-Boolean $DryRun
$ResultStatus = "Success"
$ErrorMessage = ""
$global:CurrentAction = ""
$ScriptName = $((Split-Path $PSCommandPath -Leaf) -Replace '.ps1', $null)

#region set our defaults for the our functions
#region Write-CMLogEntry defaults
$Bias = Get-WmiObject -Class Win32_TimeZone | Select-Object -ExpandProperty Bias
$PSDefaultParameterValues.Add("Write-CMLogEntry:Bias", $Bias)
$PSDefaultParameterValues.Add("Write-CMLogEntry:FileName", [string]::Format("{0}-{1}.log", $RBInstance, $ComputerName))
$PSDefaultParameterValues.Add("Write-CMLogEntry:Folder", $LogLocation)
$PSDefaultParameterValues.Add("Write-CMLogEntry:Component", "[$ComputerName]::[$ScriptName]")
#endregion Write-CMLogEntry defaults

#region Update-DBServerStatus defaults
$PSDefaultParameterValues.Add("Update-DBServerStatus:ComputerName", $ComputerName)
$PSDefaultParameterValues.Add("Update-DBServerStatus:RBInstance", $RBInstance)
$PSDefaultParameterValues.Add("Update-DBServerStatus:SQLServer", $SQLServer)
$PSDefaultParameterValues.Add("Update-DBServerStatus:Database", $OrchStagingDB)
#endregion Update-DBServerStatus defaults

#region Start-CompPatchQuery defaults
$PSDefaultParameterValues.Add("Start-CompPatchQuery:SQLServer", $SQLServer)
$PSDefaultParameterValues.Add("Start-CompPatchQuery:Database", $OrchStagingDB)
#endregion Start-CompPatchQuery defaults
#endregion set our defaults for our functions

Write-CMLogEntry "Runbook activity script started - [Running On = $env:ComputerName]"
Update-DBServerStatus -Status "Started $ScriptName"
Update-DBServerStatus -Stage 'Start' -Component $ScriptName -DryRun $DryRun

try {
    Write-CMLogEntry "Will load $ScriptType for $ComputerName from $OrchStagingDB"
    #region create credential objects
    Write-CMLogEntry "Creating necessary credential objects"
    $RemotingCreds = Get-StoredCredential -ComputerName $ComputerName -SQLServer $SQLServer -Database $OrchStagingDB
    #endregion create credential objects

    $FQDN = Get-FQDNFromDB -ComputerName $ComputerName -SQLServer $SQLServer -Database $OrchStagingDB -SQLServer $SQLServer -Database $OrchStagingDB

    #region gather script from database
    Write-CMLogEntry "Querying $OrchStagingDB for $ScriptType for $ComputerName"
    $ScriptQuery = [string]::Format("SELECT {0} from [dbo].[ServerStatus] WHERE ServerName = '{1}'", $ScriptType, $ComputerName)
    $Script = Start-CompPatchQuery -Query $ScriptQuery
    if ($Script.$ScriptType.GetType().Name -ne 'DBNull') {
        $Script = $Script | Select-Object -ExpandProperty $ScriptType
        Write-CMLogEntry "$ScriptType found"
        $ScriptBlock = [scriptblock]::Create($Script)
        switch ($ScriptType) {
            DrainScript { 
                $RunLocationField = 'DrainScriptRunLocation'
            }
            ResumeScript {
                $RunLocationField = 'ResumeScriptRunLocation'
            }
        }
        Write-CMLogEntry "Based on [ScriptType=$ScriptType] performing query `"SELECT $RunLocationField from [dbo].[ServerStatus] WHERE ServerName = '$ComputerName'`""
        $RunLocationQuery = [string]::Format("SELECT {0} from [dbo].[ServerStatus] WHERE ServerName = '{1}'", $RunLocationField, $ComputerName)
        $RunLocation = Start-CompPatchQuery -Query $RunLocationQuery | Select-Object -ExpandProperty $RunLocationField
        Write-CMLogEntry "[RunLocation=$RunLocation]"
        switch ($RunLocation) {
            Remote {        
                Invoke-Command -ComputerName $FQDN -ScriptBlock $ScriptBlock -Credential $RemotingCreds -ErrorAction Stop
            }
            Local {
                & $ScriptBlock
            }
        }
    }
    else {
        Write-CMLogEntry "No $ScriptType found for $FQDN - step will be skipped"
    }
    #endregion gather script from database
}
catch {
    # Catch any errors thrown above here, setting the result status and recording the error message to return to the activity for data bus publishing
    $ResultStatus = "Failed"
    $ErrorMessage = $error[0].Exception.Message
    $LastStatus = "Failed: $global:CurrentAction"
    [string]$Now = [System.TimeZoneInfo]::ConvertTimeBySystemTimeZoneId((Get-Date), 'Eastern Standard Time')
    $NoteFailureQuery = [string]::Format("UPDATE [dbo].[ServerStatus] SET LastStatus='{0}', TimeStamp='{1}' WHERE ServerName='{2}'", $LastStatus, $Now, $ComputerName)
    Start-CompPatchQuery -Query $NoteFailureQuery
    Write-CMLogEntry "Exception caught during action [$global:CurrentAction]: $ErrorMessage" -Severity 3
}
finally {
    # Always do whatever is in the finally block. In this case, adding some additional detail about the outcome to the trace log for return
    if ($ErrorMessage.Length -gt 0) {
        Write-CMLogEntry "Exiting script with result [$ResultStatus] and error message [$ErrorMessage]" -Severity 3
    }
    else {
        Write-CMLogEntry "Exiting script with result [$ResultStatus]"
    }
}
# Record end of activity script process
Update-DBServerStatus -Status "Finished $ScriptName" -LastStatus "$ScriptType $ResultStatus"
Update-DBServerStatus -Stage 'End' -Component $ScriptName
Write-CMLogEntry "Script finished"