DESCRIPTION

	Map for the GARMIN devices. Data source: OpenStreetMap. This build was
	created with the following software:
		osm2mp (https://github.com/liosha/osm2mp)
		cgpsmapper		
	
REQUIREMENTS

	You will require MapSource or BaseCamp to install this map (both can
	be downloaded from garmin.com). WARNING: BaseCamp 4.7.0 (and newer)
	can use only GMAPI format. If you use Linux, you can try QLandkarteGT,
	but the result may vary.

ATTENTION

	Do not use this product as the only source of information about the area. 
	It may contain incomplete or inaccurate data, some features are missing 
	compared to the Garmin products. And there are some issues that are impossible 
	to fix at the moment. Always plan your route and check map quality before the trip.

INSTALLATION (MAPSOURCE)

	- Unpack the map into the separate folder (you can use 7zip archiver
	  from 7-zip.org)
	- Install map
		-IMG: run INSTALL.BAT script as administrator
		-GMAPI: copy FAMILY_XXX.gmapi\FAMILY_XXX.gmap (or create shortcut)
			into C:\users\<user's name>\AppData\Roaming\Garmin\Maps 
				(Windows 7-10)
			or into C:\Documents and Settings\<user's name>\Application Data\Garmin\Maps
				(Windows XP)
	- Plug in your device
	- Start MapSource
	- Choose a map from the list (in the upper left corner)
	- Click the Tools menu
	- Click the Map option
	- Select the map with your mouse (not just click, but select a rectangular
	  area)
	- Click the Transfer menu
        - Click Send To Device option in the Transfer menu
	
INSTALLATION (BASECAMP)

	- Unpack the map into the separate folder (you can use 7zip archiver
	  from 7-zip.org)
	- Install map
		-IMG: run INSTALL.BAT script as administrator
		-GMAPI: copy FAMILY_XXX.gmapi\FAMILY_XXX.gmap (or create shortcut)
			into C:\users\<user's name>\AppData\Roaming\Garmin\Maps 
				(Windows 7-10)
			or into C:\Documents and Settings\<user's name>\Application Data\Garmin\Maps
				(Windows XP)
	- Plug in your device
	- Start BaseCamp
	- Choose a map from the list in the toolbox
	- Click the Utilities menu
	- Click the Install Map option
	- Choose your device
	- Select the map with your mouse (not just click, but select a rectangular
	  area)
	- Install
	  
INSTALLATION (OSX)

GMAPI
	- Unpack the map into the separate folder (you can use 7zip archiver
	- Open FAMILY_XXX.gmap
	- see INSTALLATION (BASECAMP)

IMG
	- Install the map on a Windows PC
	- Convert the map using MapConverter from Garmin
	  http://www8.garmin.com/support/download_details.jsp?id=3897
	- Install converted map on the OSX using Map Manager software
	  http://www8.garmin.com/osx/
	- see INSTALLATION (BASECAMP)

KNOWN PROBLEMS

	- BaseCamp version 4.7.0 or later cannot install IMG maps correctly, use GMAPI 
		format
	- The latest versions of BaseCamp and some devices cannot build route correctly
		when you use "Driving" (automobile) activity profile. Switch to 
		"Motorcycling" profile. It has some limitations though: access restrictions
		for the roads will be ignored
	- BaseCamp 4.8.4 for MacOS does not display Russian letters in map names and 
		object labels. Garmin support recommends installing version 4.7.0 before
		they fix this bug.

SUPPORT

	http://forum.openstreetmap.org/viewtopic.php?id=2367

COPYRIGHT

	http://www.openstreetmap.org/copyright

