@echo off
SET version=0.1.0
SET type=stable
SET devroot=..\LMS-CPlus
xcopy "%devroot%\CHANGELOG" "%devroot%\plugin" /y /d
CALL :zipxml %type%
goto :eof

:zipxml 
"c:\perl\bin\perl" ..\LMS\package.pl version "%devroot%" CPlus %version% %1
del "%devroot%\CPlus*.zip"
"C:\Program Files\7-Zip\7z.exe" a -r "%devroot%\CPlus-%version%.zip" "%devroot%\plugin\*"
"c:\perl\bin\perl" ..\LMS\package.pl sha "%devroot%" CPlus %version% %1
if %1 == stable xcopy "%devroot%\CPlus-%version%.zip" "%devroot%\..\LMS\" /y /d
goto :eof


