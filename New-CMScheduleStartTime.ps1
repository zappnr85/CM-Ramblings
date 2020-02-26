Function New-CMScheduleStartTime {
    [CmdletBinding()]
    <#
        .SYNOPSIS
            Recreate a CMSchedule object with a new start time
        .DESCRIPTION
            Natively, the CMSchedule objects do not allow you to write to the StartTime property. This makes it
            difficult to adjust the start time of an existing maintenance window. This function can be used to
            'recreate' a CMSchedule based on the input schedule, with a new start time.
        .PARAMETER CMSchedule
            An array of CMSchedule objects
        .PARAMETER StartTime
            The desired new start time for the schedule
        .EXAMPLE
            CCM:\> $Sched = Get-CMMaintenanceWindow -CollectionName 'test'
                $Schedobject = Convert-CMSchedule -ScheduleString $Sched.ServiceWindowSchedules
                New-CMScheduleStartTime -CMSchedule $Schedobject -StartTime $Schedobject.StartTime.AddDays(5)
        .NOTES
            FileName:    New-CMScheduleStartTime.ps1
            Author:      Cody Mathis
            Contact:     @CodyMathis123
            Created:     2020-02-26
            Updated:     2020-02-26
    #>
    Param(
        [Parameter(Mandatory = $true, ValueFromPipelineByPropertyName = $true)]
        [Alias('Schedules')]
        [Microsoft.ConfigurationManagement.ManagementProvider.WqlQueryEngine.WqlResultObjectBase[]]$CMSchedule,
        [Parameter(Mandatory = $true)]
        [datetime]$StartTime
    )
    begin {
        $NewSchedSplat = @{
            Start = $StartTime
        }
    }
    process {
        foreach ($Schedule in $CMSchedule) {
            $RecurType = $Schedule.SmsProviderObjectPath
            $DayDuration = $Schedule.DayDuration
            $HourDuration = $Schedule.HourDuration
            $MinuteDuration = $Schedule.MinuteDuration
            $NewEndTime = $StartTime.AddDays($DayDuration).AddHours($HourDuration).AddMinutes($MinuteDuration)
            $NewSchedSplat['End'] = $NewEndTime
            $NewSchedSplat['IsUTC'] = $Schedule.IsGMT
            Switch ($RecurType) {
                SMS_ST_NonRecurring {
                    $DayDuration = $Schedule.DayDuration
                    $HourDuration = $Schedule.HourDuration
                    $MinuteDuration = $Schedule.MinuteDuration
                    $NewEndTime = $StartTime.AddDays($DayDuration).AddHours($HourDuration).AddMinutes($MinuteDuration)
                    $NewSchedSplat['Nonrecurring'] = $true
                }
                SMS_ST_RecurInterval {
                    if ($Schedule.MinuteSpan -ne 0) {
                        $Span = 'Minutes'
                        $Interval = $Schedule.MinuteSpan
                    }
                    elseif ($Schedule.HourSpan -ne 0) {
                        $Span = 'Hours'
                        $Interval = $Schedule.HourSpan
                    }
                    elseif ($Schedule.DaySpan -ne 0) {
                        $Span = 'Days'
                        $Interval = $Schedule.DaySpan
                    }
                    $NewSchedSplat['RecurInterval'] = $Span
                    $NewSchedSplat['RecurCount'] = $Interval
                }
                SMS_ST_RecurWeekly {
                    $Day = $Schedule.Day
                    $WeekRecurrence = $Schedule.ForNumberOfWeeks
                    $NewSchedSplat['DayOfWeek'] = [DayOfWeek]($Day - 1)
                    $NewSchedSplat['RecurCount'] = $WeekRecurrence
                }
                SMS_ST_RecurMonthlyByWeekday {
                    $Day = $Schedule.Day
                    $ForNumberOfMonths = $Schedule.ForNumberOfMonths
                    $WeekOrder = $Schedule.WeekOrder
                    $NewSchedSplat['DayOfWeek'] = [DayOfWeek]($Day - 1)
                    $NewSchedSplat['WeekOrder'] = $WeekOrder
                    $NewSchedSplat['RecurCount'] = $ForNumberOfMonths
                }
                SMS_ST_RecurMonthlyByDate {
                    $DayDuration = $Schedule.DayDuration
                    $HourDuration = $Schedule.HourDuration
                    $MinuteDuration = $Schedule.MinuteDuration
                    $NewEndTime = $StartTime.AddDays($DayDuration).AddHours($HourDuration).AddMinutes($MinuteDuration)
                    $NewSchedSplat['DayOfMonth'] = $Schedule.MonthDay
                    $NewSchedSplat['RecurCount'] = $Schedule.ForNumberOfMonths
                }
                Default {
                    Write-Error "Parsing Schedule String resulted in invalid type of $RecurType"
                }
            }
            New-CMSchedule @NewSchedSplat
        }
    }
}