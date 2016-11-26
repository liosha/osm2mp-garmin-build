#! /usr/local/bin/python
#coding=utf-8

'''
Created on 03.08.2012
Modified on 08.08.2012

@author: gryphon
@license: WTFPL v2.0
@summary: download broken multipolygons

STDIN - ОСМ файл содержащий мультиполигоны загруженные неполностью
STDOUT - ОСМ файл содержащий только полные версии мультиполигонов из исходного файла

08.08.2012	запись в лог списка отношений
		добавлены мультиполигоны waterway
'''

import sys
from xml.etree import cElementTree as ElementTree
import urllib
import urllib2
import logging
import argparse

overpass_api_dict = {
    'op_ru' : 'http://overpass.osm.rambler.ru/cgi/interpreter',
    'op_de' : 'http://overpass-api.de/api/interpreter'
}

logging.basicConfig(level=logging.DEBUG,format="%(asctime)s %(levelname)s %(message)s")
logger=logging.getLogger(__name__)

logger.info("start")

parser = argparse.ArgumentParser(description="Parses input OSM file and downloads relations with missing parts")
parser.add_argument("--api",choices=['op_ru','op_de'],default="op_ru",
        help="overpass api provider: op_de|op_ru (default: op_ru)")
args = parser.parse_args();

overpass_api = overpass_api_dict[args.api]

relations=dict()
ways=set()
curmembers=set()
logger.info("parsing input stream")
for (event,elem) in ElementTree.iterparse(sys.stdin):
    if (elem.tag=="member" and elem.attrib["type"]=="way"):
        memref=long(elem.attrib["ref"])
        curmembers.add(memref)
    if (elem.tag=="relation"):
        relid=long(elem.attrib["id"])
        isMpoly=False
        isNatural=False
        for tag in elem.iter("tag"):
            if (tag.attrib["k"] in ["natural","landuse","waterway"]):
                isNatural=True
            if (tag.attrib["k"]=="type" and tag.attrib["v"]=="multipolygon"):
                isMpoly=True
        if isMpoly and isNatural:
            relations[relid]=curmembers
        curmembers=set()
    if (elem.tag=="way"):
        wayid=long(elem.attrib["id"])
        if wayid not in ways:
            ways.add(wayid)
    if elem.tag!="tag":
        elem.clear()

mpolys=set()
for relid in relations.iterkeys():
    if not relations[relid]<=ways:
        mpolys.add(relid)
del relations
del ways

logger.info("found {0} broken multipolygons".format(len(mpolys)))
logger.info(str(mpolys))

logger.info("creating overpass query")
dataquery="("
for relid in mpolys:
    dataquery+="rel("+str(relid)+");\n"
dataquery+=");\n"
dataquery+="(._;\n"
dataquery+=">;\n"
dataquery+=");\n"
dataquery+="out meta;\n"
values= {"data":dataquery}
encdata = urllib.urlencode(values)

logger.info("sending http request")
isSent=False
for count in range(0,3):
    try:
        req = urllib2.Request(url=overpass_api, data=encdata)
        f = urllib2.urlopen(req,timeout=300)
        print f.read()
        f.close()
        isSent=True
        break
    except IOError as e:
        logger.error("can't send request: {0}".format(e))
logger.info("finish")
if not isSent:
    exit(1)
