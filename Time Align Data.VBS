'-------------------------------------------------------------------------------
'-- VBS script file
'-- Created on 07/03/2013 11:44:42
'-- Author: Stephen Barrett
'-- Comment: This script searches for waveforms channels, NI VeriStand single point time channels, and XNET time
'channels. It then applies scaling to the time channels and x-offsets to the waveforms so they line up correctly,
'relatively, in time on a DIAdem 2D Axis System. The algorithm: When a waveform or time channel is found, 
'get each of their first time values (t0), bring values to a common format (seconds since 1904), sort them to
'find the first t0, and then apply the appropriate scale to the time channels or x-offset to the waveforms.
'-------------------------------------------------------------------------------
OPTION EXPLICIT
Dim i, j, x, iMax, oMyChn, MyTimeChns, firstt0, Offset, TZOffset, DSTOffset, WarnMsg, WarnFlag

'When DIAdem reads dateTime data, it converts it to the local time zone of this computer. However, when logging
'the absolute time channel from NI VeriStand as a double, this is in UTC format. This offset must be compensated for. 
TZOffset = GetTimeZoneOffset()
DSTOffset = GetDSTOffset()

j = -1
iMax = GlobUsedChn
ReDim MyTimeChns(iMax)

FOR i = 1 TO iMax
  Set oMyChn = Data.GetChannel(i)
  
  IF ChnWfKey(oMyChn) THEN ' This is a waveform channel
    j = j + 1
    oMyChn.Properties("wf_xname").Value = "Time"
    oMyChn.Properties("wf_xunit_string").Value = "s"
    Offset = SecSince1904(oMyChn.Properties("wf_start_time"), true)
    Set MyTimeChns(j) = New TimeChn
    MyTimeChns(j).ChnIdx = i
    MyTimeChns(j).Wfm = TRUE
    MyTimeChns(j).t0 = Offset
    
  ElseIF IsAbsTimeChn(oMyChn) THEN
    'This is a single point channel with DBL values in seconds since lv epoch or as dateTime variants (an option in NIVS 2013 and later) 
    j = j + 1
    Set MyTimeChns(j) = New TimeChn
    MyTimeChns(j).ChnIdx = i
    MyTimeChns(j).Wfm = FALSE
    IF oMyChn.Properties.Exists("AlignExample_t0") THEN
      MyTimeChns(j).t0 = oMyChn.Properties("AlignExample_t0").Value
    ElseIF oMyChn.DataType = DataTypeChnDate THEN 'dateTime variant (NIVS 2013 or later). 
      'Known issue: DIAdem cannot handle more than 0.1ms of precision with these data types! Add warning suggestion
      Call oMyChn.Properties.Add("AlignExample_formatWarning", 1)
      Offset = oMyChn.dValues(1) - 60084288000 'convert from 0 AD epoch to 1904 epoch (LabVIEW format)
      'TimeZone Correction
      Offset = Offset - TZOffset
      if (isDST(oMyChn.Values(1))=1) then
        Offset = Offset - DSTOffset
      end if
      ChnDim(oMyChn) = "s"
      ChnFormat(oMyChn) = "Numeric"
      Call oMyChn.Properties.Add("AlignExample_t0", Offset, DataTypeFloat64)
      MyTimeChns(j).t0 = Offset
    ELSE ' channel with DBL values in seconds since lv epoch
      Offset = oMyChn.Values(1)
      Call oMyChn.Properties.Add("AlignExample_t0", Offset, DataTypeFloat64)
      MyTimeChns(j).t0 = Offset
    END IF
    IF oMyChn.Properties.Exists("AlignExample_formatWarning") THEN
      WarnMsg = WarnMsg & oMyChn.ChannelGroup.Name & "/" & oMyChn.Name & vbCRLF
      WarnFlag = TRUE
    END IF
    
  ElseIF IsXnetTimeChn(oMyChn) THEN
    'This is an XNET time channel with values in seconds starting at 0. To find the absolute time of the first time stamp, there is a property
    'on the group level. In DIAdem 2012 and later with the XNET TDMS converter time precision patch, that property is "CANDateTimeStamp" of
    'datatype: dateTime object (which is high precision). In all versions of DIAdem, there is a "CANTimeStamp" property of datatype
    'DBL (0.1ms precision) in seconds since 0 AD.
    j = j + 1
    Set MyTimeChns(j) = New TimeChn
    MyTimeChns(j).ChnIdx = i
    MyTimeChns(j).Wfm = FALSE
    IF oMyChn.Properties.Exists("AlignExample_t0") THEN
      MyTimeChns(j).t0 = oMyChn.Properties("AlignExample_t0").Value
    ElseIF oMyChn.ChannelGroup.Properties.Exists("CANDateTimeStamp") THEN
      Offset = SecSince1904(oMyChn.ChannelGroup.Properties("CANDateTimeStamp"), false)
      MyTimeChns(j).t0 = Offset
      Call oMyChn.Properties.Add("AlignExample_t0", Offset, DataTypeFloat64)
    Else
      Offset = oMyChn.ChannelGroup.Properties("CANTimeStamp").Value - 60084288000 'convert from 0 AD epoch to 1904 epoch (LabVIEW format)
      MyTimeChns(j).t0 = Offset
      Call oMyChn.Properties.Add("AlignExample_t0", Offset, DataTypeFloat64)
    END IF
  END IF
NEXT ' i, Channel

IF j >= 1 THEN
  IF WarnFlag THEN
    MsgBox "WARNING! These time channels were found in Absolute Time format: " & vbCRLF & WarnMsg &_
    "The maximum precision DIAdem offers for this type is only 0.1ms. Consider logging time in Absolute Time as Double format in the future."
  END IF
  ReDim Preserve MyTimeChns(j)
  Call BubbleSortTimeChns(MyTimeChns)
  firstt0 = MyTimeChns(0).t0
  'Dim Msg 'For debugging
  FOR Each x in MyTimeChns
    'Msg = Msg & x.t0 & vbCRLF 'For debugging
    Set oMyChn = Data.GetChannel(x.ChnIdx)
    IF (x.wfm) THEN
      oMyChn.Properties("wf_start_offset").Value = (x.t0 - firstt0)
    ELSE
      Offset = (x.t0 - firstt0) - oMyChn.dValues(1)
      Call ChnLinScale(oMyChn, oMyChn, 1, Offset)
    END IF
  NEXT ' x, TimeChannel
  'MsgBox firstt0 & vbCRLF & "---------------------" & vbCRLF & Msg 'For debugging
END IF ' TimeChannels found

Class TimeChn
    Public ChnIdx
    Public t0
    Public Wfm
End Class

Sub BubbleSortTimeChns(arr)
    Dim numEls
    Dim temp : set temp = New TimeChn
    Dim index
    Dim firstItem
    Dim indexLimit, lastSwap
    ' account for optional arguments
    numEls = UBound(arr)
    firstItem = LBound(arr)
    lastSwap = numEls
    Do
        indexLimit = lastSwap - 1
        lastSwap = 0
        For index = firstItem To indexLimit
            set temp = arr(index)
            If (temp.t0 > arr(index + 1).t0) Then
                ' if the items are not in order, swap them
                set arr(index) = arr(index + 1)
                set arr(index + 1) = temp
                lastSwap = index
            End If
        Next
    Loop While lastSwap
End Sub

Function IsAbsTimeChn(oChn)
  if oMyChn.Properties.Exists("System_Path") then
    if StrComp(Right(oMyChn.Properties("System_Path").Value, 13),"Absolute Time") = 0 then
      IsAbsTimeChn = true
    else
      IsAbsTimeChn = false
    end if
  else
    IsAbsTimeChn = false
  end if
end function

Function IsXNETTimeChn(oChn)
  if oMyChn.ChannelGroup.Properties.Exists("CANTimeStamp") then
    if StrComp(oMyChn.Name,"Time") = 0 then
      IsXNETTimeChn = true
    else
      IsXNETTimeChn = false
    end if
  else
    IsXNETTimeChn = false
  end if
end function

'gets the time zone offset in seconds
Function GetTimeZoneOffset()
  dim oSHell, atb
  set oShell = CreateObject("WScript.Shell") 
  atb = "HKEY_LOCAL_MACHINE\System\CurrentControlSet\" &_ 
        "Control\TimeZoneInformation\Bias" 
  GetTimeZoneOffset = -oShell.RegRead(atb) * 60 'minutes * seconds per minute
End Function

'gets the daylight savings time offset in seconds
Function GetDSTOffset()
  dim oSHell, atb
  set oShell = CreateObject("WScript.Shell") 
  atb = "HKEY_LOCAL_MACHINE\System\CurrentControlSet\" &_ 
        "Control\TimeZoneInformation\DaylightBias" 
  GetDSTOffset = -oShell.RegRead(atb) * 60 'minutes * seconds per minute
End Function

'takes in a channel property containing the waveform start time and returns a double in seconds
'relative to 12:00 a.m., Friday, January 1, 1904, Universal Time [01-01-1904 00:00:00].
function SecSince1904(WfStartTimeProp, ApplyTZOffset)
  dim i, oTime, vbTime
  set oTime = WfStartTimeProp.oValue
  vbTime = WfStartTimeProp.Value
  
  'TimeZone Correction
  if ApplyTZOffset then
    SecSince1904 = SecSince1904 - TZOffset
    if (isDST(vbTime)=1) then
      SecSince1904 = SecSince1904 - DSTOffset
    end if
  end if
  
  'years
  SecSince1904 = SecSince1904 + ((oTime.Year-1) - 1903) * 31536000 'seconds per year
  
  'leap years
  For i = 1904 to (oTime.Year-1)
    if IsLeapYear(i) then 'if this is a leap year add the extra day's worth of seconds
        SecSince1904 = SecSince1904 + 86400 'seconds in a single day
    end if
  Next
  
  'months
  For i = 1 to (oTime.Month-1)
    if (i=1) OR (i=3) OR (i=5) OR (i=7) OR (i=8) OR (i=10) OR (i=12) then 'months with 31 days
      SecSince1904 = SecSince1904 + 2678400 'seconds in 31 days
    elseif (i=2) then 'February has 28 or 29 days depending on leap year
      SecSince1904 = SecSince1904 + 2419200 'seconds in 28 days
      if IsLeapYear(oTime.Year) then 'if this is a leap year add the extra day's worth of seconds
        SecSince1904 = SecSince1904 + 86400 'seconds in a single day
      end if
    else 'months with 30 days
      SecSince1904 = SecSince1904 + 2592000 'seconds in 30 days
    end if
  Next
  
  'days
  SecSince1904 = SecSince1904 + ((oTime.Day-1) * 86400)
  
  'hours
  SecSince1904 = SecSince1904 + ((oTime.Hour) * 3600)
  
  'minutes
  SecSince1904 = SecSince1904 + ((oTime.Minute) * 60)
  
  'seconds
  SecSince1904 = SecSince1904 + oTime.Second
  
  'Millisecond
  SecSince1904 = SecSince1904 + (oTime.Millisecond / 1000) 
  
  'Microsecond
  SecSince1904 = SecSince1904 + (oTime.Microsecond / 1000000) 
  
  'Nanosecond
  SecSince1904 = SecSince1904 + (oTime.Nanosecond / 1000000000)
end function

Function IsLeapYear(Year)
  If Year Mod 400 = 0 Then
    IsLeapYear = True
  ElseIf Year Mod 100 = 0 Then
    IsLeapYear = False
  ElseIf Year Mod 4 = 0 Then
    IsLeapYear = True
  Else
    IsLeapYear = False
  End If
End Function 

' isDST() - Returns 1 if a date is in DST, 0 if not, -1 on bad date
 Function isDST(argDate)
 Dim StartDate, EndDate
 
 If (Not IsDate(argDate)) Then
  argReturn(0) = -1
  argReturn(1) = -1
  isDST = -1
  Exit Function
 End If
 
 ' DST start date...
 StartDate = DateSerial(Year(argDate), 3, 1)
 Do While (WeekDay(StartDate) <> vbSunday)
  StartDate = StartDate + 1
 Loop
 StartDate = StartDate + 7
 
 ' DST end date...
 EndDate = DateSerial(Year(argDate), 11, 1)
 Do While (WeekDay(EndDate) <> vbSunday)
  EndDate = EndDate + 1
 Loop

  ' Finish up...
 isDST = 0
 If ((argDate >= StartDate) And (argDate < EndDate)) Then
  isDST = 1
 End If
End Function