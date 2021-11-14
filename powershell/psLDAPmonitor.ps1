# File name          : psLDAPmonitor.ps1
# Author             : Podalirius (@podalirius_)
# Date created       : 17 Oct 2021
# Updated by	     : 1nTh35h311 (@yossi_sassi)
# Date updated       : 7 Nov 2021

Param (
    [parameter(Mandatory=$false)][string]$dcip = $null,
    [parameter(Mandatory=$false)][string]$Username = $null,
    [parameter(Mandatory=$false)][string]$Password = $null,
    [parameter(Mandatory=$false)][string]$LogFile = $null,
    [parameter(Mandatory=$false)][int]$PageSize = 5000,
    [parameter(Mandatory=$false)][int]$Delay = 1,
    [parameter(Mandatory=$false)][switch]$LDAPS,
    [parameter(Mandatory=$false)][switch]$Randomize,
    [parameter(Mandatory=$false)][switch]$IgnoreUserLogons,
    [parameter(Mandatory=$false)][switch]$Help
)

If ($Help) {
    Write-Host "[+]================================================================================"
    Write-Host "[+] Powershell LDAP live monitor v1.1b      @podalirius_ (updated by @yossi_sassi) "
    Write-Host "[+]================================================================================"
    Write-Host ""

    Write-Host "Required arguments:"
    Write-Host "  -dcip       : LDAP host to target, most likely the domain controller."
    Write-Host ""
    Write-Host "Optional arguments:"
    Write-Host "  -Help       : Displays this help message"
    Write-Host "  -Username   : User to authenticate as."
    Write-Host "  -Password   : Password for authentication."
    Write-Host "  -PageSize   : Sets the LDAP page size to use in queries (default: 5000)."
    Write-Host "  -LDAPS      : Use LDAPS instead of LDAP."
    Write-Host "  -LogFile    : Log file to save output to."
    Write-Host "  -Delay      : Delay between two queries in seconds (default: 1)."
    Write-Host "  -Randomize  : Randomize delay between two queries, between 1 and 5 seconds."
    Write-Host "  -IgnoreUserLogons  : Ignores user logon events."

    exit 0
}

If ($LogFile.Length -ne 0) {
    # Init log file
    $Stream = [System.IO.StreamWriter]::new($LogFile)
    $Stream.Close()
}

if ($Delay) {
    $DelayInSeconds = $Delay;
} else {
    $DelayInSeconds = 1;
}

#===============================================================================

$Global:Color = "Cyan";
Function Invoke-ColorChange {
	if ($Global:Color -eq "Yellow") {$Global:Color = "Cyan"}
	else
	{
	$Global:Color = "Yellow";
	}			
}

Function Write-Logger {
    [CmdletBinding()]
    [OutputType([Nullable])]
    Param
    (
        [Parameter(Mandatory=$true)] $Logfile,
        [Parameter(Mandatory=$true)] $Message
    )
    Begin
    {
	Write-Host $Message -Foregroundcolor $global:Color;
        If ($LogFile.Length -ne 0) {
            $Stream = [System.IO.StreamWriter]::new($LogFile, $true)
            $Stream.WriteLine($Message)
            $Stream.Close()
        }
    }
}

Function ResultsDiff {
    [CmdletBinding()]
    [OutputType([Nullable])]
    Param
    (
        [Parameter(Mandatory=$true)] $Before,
        [Parameter(Mandatory=$true)] $After,
        [Parameter(Mandatory=$true)] $connectionString,
        [Parameter(Mandatory=$true)] $Logfile,
        [parameter(Mandatory=$false)][switch]$IgnoreUserLogons
    )
    Begin {
        [System.Collections.ArrayList]$ignored_keys = @();
        If ($IgnoreUserLogons) {
            $ignored_keys.Add("lastlogon") | Out-Null
            $ignored_keys.Add("logoncount") | Out-Null
        }

        $dateprompt = ("[{0}] " -f (Get-Date -Format "yyyy/MM/dd hh:mm:ss"));
        # Get Keys
        $dict_results_before = [ordered]@{};
        $dict_results_after = [ordered]@{};
        Foreach ($itemBefore in $Before) { $dict_results_before[$itemBefore.Path] = $itemBefore.Properties; }
        Foreach ($itemAfter in $After) { $dict_results_after[$itemAfter.Path] = $itemAfter.Properties; }

        # Get created and deleted entries, and common_keys
        [System.Collections.ArrayList]$commonPaths = @();
        Foreach ($bpath in $dict_results_before.Keys) {
            if (!($dict_results_after.Keys -contains $bpath)) {
                Write-Logger -Logfile $Logfile -Message  ("{0}'{1}' was deleted." -f $dateprompt, $bpath.replace($connectionString+"/",""))
            } else {
                $commonPaths.Add($bpath) | Out-Null
            }
        }
        Foreach ($apath in $dict_results_after.Keys) {
            if (!($dict_results_before.Keys -contains $apath)) {
                Write-Logger -Logfile $Logfile -Message  ("{0}'{1}' was created." -f $dateprompt, $apath.replace($connectionString+"/",""))
            }
        }

        # Iterate over all the common keys
        [System.Collections.ArrayList]$attrs_diff = @();
        Foreach ($path in $commonPaths) {
            $attrs_diff.Clear();

            # Convert into dictionnaries
            $dict_direntry_before = [ordered]@{};
            $dict_direntry_after = [ordered]@{};

            Foreach ($propkey in $dict_results_before[$path].Keys) {
                if (!($ignored_keys -Contains $propkey.ToLower())) {
                    $dict_direntry_before.Add($propkey, $dict_results_before[$path][$propkey][0]);
                }
            };
            Foreach ($propkey in $dict_results_after[$path].Keys) {
                if (!($ignored_keys -Contains $propkey.ToLower())) {
                    $dict_direntry_after.Add($propkey, $dict_results_after[$path][$propkey][0]);
                }
            };

            # Store different values
            Foreach ($pname in $dict_direntry_after.Keys) {
                if (($dict_direntry_after.Keys -Contains $pname) -And ($dict_direntry_before.Keys  -Contains $pname)) {
                    if (!($dict_direntry_after[$pname].ToString() -eq $dict_direntry_before[$pname].ToString())) {
                        $attrs_diff.Add(@($path, $pname, $dict_direntry_after[$pname], $dict_direntry_before[$pname])) | Out-Null;
                    }
                } elseif (($dict_direntry_after.Keys -Contains $pname) -And !($dict_direntry_before.Keys  -Contains $pname)) {
                    $attrs_diff.Add(@($path, $pname, $dict_direntry_after[$pname], $null)) | Out-Null;
                } elseif (!($dict_direntry_after.Keys -Contains $pname) -And ($dict_direntry_before.Keys  -Contains $pname)) {
                    $attrs_diff.Add(@($path, $pname, $null, $dict_direntry_before[$pname])) | Out-Null;
                }
            }

            # Show results
            if ($attrs_diff.Length -ge 0) {
                # added samaccountname, indicates better if computer or user
		Invoke-ColorChange;
                Write-Logger -Logfile $Logfile -Message  ("{0}{1}{2}" -f $dateprompt, $path.replace($connectionString+"/",""), " ($($dict_results_after[$path].samaccountname))")

                Foreach ($t in $attrs_diff) {
                if (($t[3] -ne $null) -And ($t[2] -ne $null)) {
			    # updated to include parsing dateTime fields (filetime) to friendly format
			    if ($t[1] -in $DateAttributes) {
					    $PreviousDateTime = [datetime]::fromFileTime($($t[3])); 
					    $NewDateTime = [datetime]::fromFileTime($($t[2])); 
	                	            Write-Logger -Logfile $Logfile -Message  (" | Attribute {0} changed from '{1}' to '{2}'" -f $t[1], $PreviousDateTime, $NewDateTime);
				    }
			    else
				    {
					    if ($t[1] -eq "badpwdcount") 
						    {
						            Write-Logger -Logfile $Logfile -Message  (" | Attribute {0} changed from '{1}' to '{2}' (Lockout at $LockOutBadCount bad counts)" -f $t[1], $t[3], $t[2]);
						    }
					    else
						    {
							    Write-Logger -Logfile $Logfile -Message  (" | Attribute {0} changed from '{1}' to '{2}'" -f $t[1], $t[3], $t[2]);
						    }
				    }
	            } elseif (($t[3] -eq $null) -And ($t[2] -ne $null)) {
                        Write-Logger -Logfile $Logfile -Message  (" | Attribute {0} = '{1}' was created." -f $t[1], $t[2]);
                    } elseif (($t[3] -ne $null) -And ($t[2] -eq $null)) {
                        Write-Logger -Logfile $Logfile -Message  (" | Attribute {0} = '{1}' was deleted." -f $t[1], $t[3]);
                    }
                }
            }
        }
    }
}

#===============================================================================

Write-Logger -Logfile $Logfile -Message  "[+]================================================================================"
Write-Logger -Logfile $Logfile -Message  "[+] Powershell LDAP live monitor v1.1b      @podalirius_ (updated by @yossi_sassi) "
Write-Logger -Logfile $Logfile -Message  "[+]================================================================================"
Write-Logger -Logfile $Logfile -Message  ""

# pick up default logon server IPv4 if not specified
if ($dcip -eq "" -and $env:LOGONSERVER -ne "") {
        $DCIPs = ([system.net.dns]::Resolve($($env:LOGONSERVER).Replace("\\",""))).AddressList.IPAddressToString;
        $dcip = $DCIPs | foreach {if ($_ -match "^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}$" -and [bool]($_ -as [ipaddress])) {$_}} | select -First 1;
        Write-Verbose "No -dcip specified. automatically using current Logon Server (IP: $dcip)."
    }

# Handle LDAPS connection
$connectionString = "LDAP://{0}:{1}";
If ($LDAPS) {
    $connectionString = ($connectionString -f $dcip, "636");
} else {
    $connectionString = ($connectionString -f $dcip, "389");
}
Write-Verbose "$connectionString"

# Connect to LDAP
try {
    # Connect to Domain with credentials
    if ($Username) {
        $objDomain = New-Object System.DirectoryServices.DirectoryEntry("$connectionString", $Username, $Password)
    } else {
        $objDomain = New-Object System.DirectoryServices.DirectoryEntry("$connectionString")
    }
    $searcher = New-Object System.DirectoryServices.DirectorySearcher
    $searcher.SearchRoot = $objDomain
    if ($PageSize) {
        $searcher.PageSize = $PageSize
    } else {
        Write-Verbose ("Setting PageSize to $PageSize");
        $searcher.PageSize = 5000
    }

    Write-Verbose ("Authentication successful!");

    
    # update: set dateTime attributes for better formatting 
    $DateAttributes = "lastlogon", "badpasswordtime", "lastlogontimestamp", "pwdlastset";

    # update: include LockOut bad count limit, to reflect when bad password was attempted
    [int]$LockOutBadCount = (Get-Content "\\$($ENV:USERDNSDOMAIN)\SYSVOL\$($ENV:USERDNSDOMAIN)\Policies\{31B2F340-016D-11D2-945F-00C04FB984F9}\MACHINE\Microsoft\Windows NT\SecEdit\GptTmpl.inf" | Select-String LockoutBadCount).ToString().Split("=")[1].Trim()

    # First query
    $searcher.Filter = "(objectClass=*)"
    $results_before = $searcher.FindAll();

    Write-Logger -Logfile $Logfile -Message "[>] Polling for LDAP changes (DC IP: $dcip)...";
    Write-Logger -Logfile $Logfile -Message "";

    While ($true) {
        # Update query
        $results_after = $searcher.FindAll();
        # Diff
        if ($IgnoreUserLogons) {
            ResultsDiff -Before $results_before -After $results_after -connectionString $connectionString -Logfile $Logfile -IgnoreUserLogons
        } else {
            ResultsDiff -Before $results_before -After $results_after -connectionString $connectionString -Logfile $Logfile
        }
        $results_before = $results_after;
        if ($Randomize) {
            $DelayInSeconds = Get-Random -Minimum 1 -Maximum 5
        }
        Write-Verbose ("Waiting {0} second." -f $DelayInSeconds);
        Start-Sleep -Seconds $DelayInSeconds
    }
} catch {
    Write-Verbose $_.Exception
    Write-Logger -Logfile $Logfile -Message  ("[!] (0x{0:X8}) {1}" -f $_.Exception.HResult, $_.Exception.InnerException.Message)
    exit -1
}
