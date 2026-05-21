import psycopg2

OSM_LINK = "https://download.geofabrik.de/north-america/us/florida-latest.osm.pbf"

def get_db_connection():
    return psycopg2.connect(dbname="gis", user="applem4air", host="localhost")

def initiate():
    pass

def update():
    pass