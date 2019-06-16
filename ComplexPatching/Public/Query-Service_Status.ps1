﻿param
(
    [parameter(Mandatory = $true)]
    [string]$ComputerName,
    # Provides the computer name to check services on

    [parameter(Mandatory = $true)]
    [string]$DryRun,
    # skips patching check so that we can perform a dry run of the drain an resume

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
$ErrorMessage = ""
$script:ResultStatus = 'Success'
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
    #region create credential objects
    Write-CMLogEntry "Creating necessary credential objects"
    $RemotingCreds = Get-StoredCredential -ComputerName $ComputerName -SQLServer $SQLServer -Database $OrchStagingDB
    #endregion create credential objects

    $FQDN = Get-FQDNFromDB -ComputerName $ComputerName -SQLServer $SQLServer -Database $OrchStagingDB

    #region initiate CIMSession, looping until one is made, or it has been 10 minutes
    Update-DBServerStatus -LastStatus 'Creating CIMSession'
    Write-CMLogEntry 'Creating CIMSession'
    New-LoopAction -LoopTimeout 10 -LoopTimeoutType Minutes -LoopDelay 10 -ExitCondition { $script:CIMSession } -ScriptBlock {
        $script:CIMSession = New-MrCimSession -Credential $script:RemotingCreds -ComputerName $script:FQDN
    } -IfSucceedScript { 
        Update-DBServerStatus -LastStatus "CIMSession Created"
        Write-CMLogEntry 'CIMSession created succesfully' 
    } -IfTimeoutScript {
        Write-CMLogEntry 'Failed to create CIMSession'
        throw 'Failed to create CIMsession'
    }
    #endregion initiate CIMSession, looping until one is made, or it has been 10 minutes

    #region get service strings and create query
    $GetServicesQuery = [string]::Format("Use $OrchStagingDB;Select ServiceStrings from [dbo].[ServerStatus] where ServerName='{0}' and RBInstance='{1}'", $ComputerName, $RBInstance)
    $ServiceStrings = Start-CompPatchQuery -Query $GetServicesQuery
    $ServiceStrings = $ServiceStrings.ServiceStrings -split ";"
    #endregion get service strings and create query

    #region query the current state of services and insert into the database
    if ($ServiceStrings) {
        Update-DBServerStatus -LastStatus "Querying Services"
        Write-CMLogEntry "Querying for all services matching $($ServiceStrings -join ";") and noting current state in DB prior to updates and rebooting"
        foreach ($String in $ServiceStrings) {
            $Services = Get-CimInstance -CimSession $CIMSession -ClassName Win32_Service -Filter "(Name Like '%$String%' or Caption Like '%$String%') and StartMode like '%auto%' and State='Running'" -ErrorAction Stop | Select-Object -Property Name, State, StartMode
            foreach ($Service in $Services) {
                $ServiceName = $Service.Name
                $ServiceStatus = $Service.State
                $ServiceStartup = $Service.StartMode
                Write-CMLogEntry "Identified service [ServiceName=$ServiceName] [ServiceStatus=$ServiceStatus] [ServiceStartupType=$ServiceStartup] [ComputerName=$ComputerName] [RBInstance=$RBInstance]"
                $InsertServicesQuery = [string]::Format("INSERT INTO [dbo].[Service] VALUES ('{0}','{1}','{2}','{3}','{4}')", $script:ComputerName, $ServiceName, $ServiceStatus, $ServiceStartup, $RBInstance)
                Start-CompPatchQuery -Query $InsertServicesQuery
            }
        }
        Write-CMLogEntry "All services matching $($ServiceStrings -join ";") have been inserted into the DB for [ComputerName=$ComputerName]"
        Update-DBServerStatus -LastStatus "Services Queried"
    }
    else {
        Write-CMLogEntry "No service strings in database for [ComputerName=$ComputerName]"
    }
    #endregion query the current state of services and insert into the database
}
catch {
    # Catch any errors thrown above here, setting the result status and recording the error message to return to the activity for data bus publishing
    $ResultStatus = "Failed"
    $ErrorMessage = $error[0].Exception.Message
    $LastStatus = "Failed: $global:CurrentAction"
    Update-DBServerStatus -LastStatus $LastStatus
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
    if ($CIMSession) {
        $CIMSession.Close()
    }
}
# Record end of activity script process
Update-DBServerStatus -Status "Finished $ScriptName"
Update-DBServerStatus -Stage 'End' -Component $ScriptName
Write-CMLogEntry "Script finished"