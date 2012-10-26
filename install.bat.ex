@echo off

echo Adding registry keys.

set KEY=HKLM\SOFTWARE\Wow6432Node\Garmin\MapSource
reg QUERY %KEY% 2>NUL
if not errorlevel 1 goto key_ok
set KEY=HKLM\SOFTWARE\Garmin\MapSource
:key_ok

reg ADD %KEY%\Families\FAMILY_888 /v ID /t REG_BINARY /d 7803 /f
reg ADD %KEY%\Families\FAMILY_888 /v IDX /t REG_SZ /d "%~dp0OSM.mdx" /f
reg ADD %KEY%\Families\FAMILY_888 /v MDR /t REG_SZ /d "%~dp0OSM_mdr.img" /f
reg ADD %KEY%\Families\FAMILY_888 /v TYP /t REG_SZ /d "%~dp0osm888.typ" /f

reg ADD %KEY%\Families\FAMILY_888\1 /v Loc /t REG_SZ /d "%~dp0\" /f
reg ADD %KEY%\Families\FAMILY_888\1 /v Bmap /t REG_SZ /d "%~dp0OSM.img" /f
reg ADD %KEY%\Families\FAMILY_888\1 /v Tdb /t REG_SZ /d "%~dp0OSM.tdb" /f
