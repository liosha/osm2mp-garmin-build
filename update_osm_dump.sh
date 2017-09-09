#! /bin/sh

# Обновляет гислабовский дамп OSM
# Запуск: update_osm_dump.sh <dump_fullpath> [<bound poly>]

set -e

BASEURL=http://be.gis-lab.info/data/osm_dump/dump/latest
TEMPDIR=/data/garmin/tmp

if [ $# -lt 2  ]
then
    echo "Run: update_osm_dump.sh <dump_name> <dump_fullpath> [<bound poly>]"
    exit 1
fi

DUMPPATH=$2
DUMPNAME=$1
DUMP=$DUMPPATH/${DUMPNAME}.osm.o5m
DUMPURL=$BASEURL/${DUMPNAME}.osm.pbf
DUMPMETA=$DUMPPATH/${DUMPNAME}.osm.pbf.meta
DUMPMETAURL=$BASEURL/${DUMPNAME}.osm.pbf.meta
POLY=$3

OPTIONS_OSMCV="-v -t=${TEMPDIR}/osmconvert_temp"
OPTIONS_OSMUP="-v -t=${TEMPDIR}/osmupdate_temp --out-o5m"

if [ -n "$POLY" ] 
then
    OPTIONS_OSMUP="$OPTIONS_OSMUP -B=$POLY"
fi

cd $TEMPDIR

# проверяем версию дампа на гислабе
# если дамп нарезан из свежей планеты, обновляемся

echo "checking planet version"

wget $DUMPMETAURL -O ${DUMPMETA}.new
planet_date_new=$(awk 'BEGIN{FS=/[ =]/;}$1 == "planet_version" {print $3;}' ${DUMPMETA}.new)
if [ -f "$DUMPMETA" ]
then
    planet_date=$(awk 'BEGIN{FS=/[ =]/;}$1 == "planet_version" {print $3;}' ${DUMPMETA})
fi
if [ "$planet_date" != "$planet_date_new" ]
then
    echo "remote dump was updated from planet at $planet_date_new, downloading"
    wget $DUMPURL -O ${DUMP}.new.pbf 
    echo "converting dump to o5m"
    osmconvert $OPTIONS_OSMCV ${DUMP}.new.pbf -o=${DUMP}.new.o5m
    mv -v ${DUMP}.new.o5m ${DUMP}
    rm ${DUMP}.new.pbf 
fi
mv -v ${DUMPMETA}.new ${DUMPMETA}

# обновляем локальный дамп с сервера планеты

echo "updating dump from motherplanet"
osmupdate $OPTIONS_OSMUP $DUMP ${DUMP}.new 
mv -v ${DUMP}.new ${DUMP}

