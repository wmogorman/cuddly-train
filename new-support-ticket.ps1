<# create support shortcut :: revision 3 build 6/seagull, january 2025
   script variables: usrPublic/bln

   this script, like all datto RMM Component scripts unless otherwise explicitly stated, is the copyrighted property of Datto, Inc.;
   it may not be shared, sold, or distributed beyond the Datto RMM product, whole or in part, even with modifications applied, for 
   any reason. this includes on reddit, on discord, or as part of other RMM tools. PCSM and VSAX stand as exceptions to this rule.
   	
   the moment you edit this script it becomes your own risk and support will not provide assistance with it.#>

write-host "Create 'New Support Ticket' Shortcuts for All Users"
write-host "==================================================="

#=============================================== functions ===============================================

function cdPnt ($codepoint) {
    #this is purely to keep the switch clause below somewhat readable
    return $([Convert]::ToChar([int][Convert]::ToInt32($codepoint, 16)))
}

function getPrompt ($LCID) {
    switch -regex ($LCID) {
        '0F$' {return "B$(cdPnt 00fa)$(cdPnt 00f0)u til n$(cdPnt 00fd)jan stu$(cdPnt 00f0)ningsmi$(cdPnt 00f0)a"} #icelandic
       #'38$' {return "There aren't any good Faroese translators"} #faroese
        '1D$' {return "Skapa ett nytt support$(cdPnt 00e4)rende"} #swedish
        '0A$' {return "Crear un nuevo ticket de soporte"} #spanish (universal)
       '816$' {return "Criar um novo ticket de suporte"} #portuguese (portugal)
       '416$' {return "Criar um novo t$(cdPnt 00ed)quete de suporte"} #portuguese (brazil)
        '25$' {return "Uue tugipileti loomine"} #estonian
        '15$' {return "Utw$(cdPnt 00f3)rz nowe zg$(cdPnt 0142)oszenie do pomocy technicznej"} #polish
        '14$' {return "Opprett en ny supportsak"} #norwegian (prefer bokmal)
        '13$' {return "Maak een nieuw supportticket"} #dutch
        'FE$' {return "$(cdPnt 010c)ajka napisal ta scenarij"} #illyrian
        '10$' {return "Creare un nuovo ticket di soporte"} #italian
        '0E$' {return "$(cdPnt 00DA)j t$(cdPnt 00e1)mogat$(cdPnt 00e1)si jegy l$(cdPnt 00e9)trehoz$(cdPnt 00e1)sa"} #hungarian
        '07$' {return "Ein neues Support Ticket erstellen"} #german
        '06$' {return "Opret en ny supportsag"} #kamelasa
        '0C$' {return "Cr$(cdPnt 00e9)er un nouveau ticket de Support"} #french
        '0B$' {return "Tee uusi tukipyynt$(cdPnt 00f6)"} #suomi mainittu
        '09$' {return "ActaMSP Support"} #english
      default {return "ActaMSP Support"} #something else $(cdPnt 2122)
    }
}

#================================================= code ==================================================

#set the table
write-host "- Enumerating Users..."
$arrUser=@{}
[int]$varCounter=0
if ([intptr]::Size -eq 8) {$varProgramFiles=${env:ProgramFiles(x86)}} else {$varProgramFiles=$env:ProgramFiles}

$arrUserSID=@{}
$arrUserLoaded=@()

#enumerate users and add those with valid NTUSER.DAT files to the array
gci "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList" | % {Get-ItemProperty $_.PSPath} | ? {$_.PSChildName -match '^S-1-5-21-'} | % {
    $varObject=New-Object PSObject
    $varObject | Add-Member -MemberType NoteProperty -Name "Username" -Value "$(split-path $_.ProfileImagePath -Leaf)"
    $varObject | Add-Member -MemberType NoteProperty -Name "ImagePath" -Value "$($_.ProfileImagePath)"
    if (Test-Path "$($_.ProfileImagePath)\NTUser.dat") {
        write-host "- Adding user [$(split-path $_.ProfileImagePath -Leaf)] to list"
        $arrUserSID+=@{$($_.PSChildName)=$varObject}
    } else {
        write-host "- Not adding user [$(split-path $_.ProfileImagePath -Leaf)] (No NTUSER.DAT hive)"
    }
}

#enumerate hku, only show user sids. from here, show entries that aren't in the arruser table we just populated.
$arrUserSID.Keys | ? {$_ -notin $(gci "Registry::HKEY_USERS" | % {$_.name} | % {split-path $_ -leaf})} | % {
    #load this user's hive
    write-host "- User $($arrUserSID[$_].Username) is not logged in; loading hive..."
    cmd /c "reg load `"HKU\$($_)`" `"$($arrUserSID[$_].ImagePath)\NTUSER.DAT`"" 2>&1>$null
    if (!$?) {
        write-host "! ERROR: Could not load Registry hive for user $($arrUserSID[$_].Username) (Check StdErr)."
        cmd /c "reg load `"HKU\$($_)`" `"$($arrUserSID[$_].ImagePath)\NTUSER.DAT`""
        write-host "  Execution cannot continue."
        exit 1
    }
    $arrUserLoaded+=$_
}

$arrUser=@{}
[int]$varCounter=0

#loop through all users with profile data and get localised strings and desktop locations for each
if ($env:usrPublic -match 'true') {
    #preamble
    write-host "- Component has been instructed to make a single shortcut in the PUBLIC directory (usrPublic option)."
    write-host "  This will produce a single shortcut in the Public Desktop folder which will reflect on all Desktops."
    write-host "  If one user deletes this shortcut it will disappear for all users of the system."
    #do the do
    $varObject=New-Object PSObject
    $varObject | Add-Member -MemberType NoteProperty -Name "Desktop" -Value "$((get-itemproperty "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList" -Name Public).Public)\Desktop"
    $varObject | Add-Member -MemberType NoteProperty -Name "LocalString" -Value "$(getPrompt (Get-ItemProperty "HKLM:\SYSTEM\ControlSet001\Control\nls\Language" -Name Default).Default)"
    $arrUser+=@{$varCounter=$varObject}
} else {
    gci "Registry::HKEY_USERS" -ea 0 | ? {$_.Name -match 'S-1-5-21' -and $_.Name -match '[0-9]$'} | % {
        $varObject=New-Object PSObject
        $varObject | Add-Member -MemberType NoteProperty -Name "Desktop" -Value "$((get-itemProperty "Registry::$($_.Name)\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Shell Folders" -name Desktop).Desktop)"
        $varObject | Add-Member -MemberType NoteProperty -Name "LocalString" -Value "$(getPrompt (Get-ItemProperty "Registry::$($_.Name)\Control Panel\International" -Name Locale).Locale)"
        $arrUser+=@{$varCounter=$varObject}
        $varCounter++
    }
}

#unload user hives
$arrUserLoaded | % {
    [gc]::Collect()
    start-sleep -seconds 3
    cmd /c "reg unload `"HKU\$($_)`"" 2>&1>$null
    if (!$?) {
        write-host "! ERROR: Could not unload Registry hive for SID $($_) (Check StdErr)."
        cmd /c "reg unload `"HKU\$($_)`""
    }
}

#display the table
write-host ": User Desktop directories have been paired with localised strings. Final table:"
$arrUser.values | ft

#produce the shortcut
$arrUser.Values | % {
    $varShortcut=(New-Object -comObject WScript.Shell).CreateShortcut("$($_.Desktop)\$($_.LocalString).lnk")
    $varShortcut.TargetPath="$varProgramFiles\CentraStage\gui.exe"
    $varShortcut.Arguments="/newticket"
    $varShortcut.Description=$($_.LocalString)
    $varShortcut.IconLocation="$env:ProgramData\CentraStage\Brand\desktopshortcut.ico"
    $varShortcut.Save()
}

write-host "- Shortcuts have been created."
