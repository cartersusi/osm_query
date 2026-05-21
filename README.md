**Download**\
https://download.geofabrik.de/north-america/us/florida-latest.osm.pbf


**Install**
```sh
postgresql osm2pgsql postgis
```

**Init**
```sh
osm2pgsql -c -d gis --slim -G --hstore florida-260518.osm.pbf
```