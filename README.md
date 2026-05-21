**Download**

OSM File: https://download.geofabrik.de/north-america/us/florida-latest.osm.pbf

Poly File: https://download.geofabrik.de/north-america/us/florida.poly

Update State File: https://download.geofabrik.de/north-america/us-updates/state.txt

Update File: https://download.geofabrik.de/north-america/us-updates/{seq_num}.osc.gz

**Updates**
```sh
osmium extract -p florida.poly {last_3_digits_seq_num}.osc.gz -o {last_3_digits_seq_num}.florida.osc.gz
osm2pgsql --append --slim -G --hstore -d gis {last_3_digits_seq_num}.florida.osc.gz
```

**Install**
```sh
brew install postgresql osm2pgsql postgis osmium-tool

```
- https://github.com/osm2pgsql-dev/osm2pgsql
- https://github.com/postgis/postgis
- https://github.com/osmcode/osmium-tool

**Init**
```sh
brew services start postgresql
postgres -p 5432
postgres -D
createdb gis
psql -d gis -c "CREATE EXTENSION postgis; CREATE EXTENSION hstore;"
osm2pgsql -c -d gis --slim -G --hstore florida-260518.osm.pbf
```