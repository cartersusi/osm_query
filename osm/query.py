from psycopg2.extras import RealDictCursor

from osm.db import get_db_connection
from osm.osm import way_data_to_json

def way_data_by_way_id(way_id: int, to_json: bool = True):
    conn = get_db_connection()
    try:
        with conn.cursor(cursor_factory=RealDictCursor) as cur:

            # 1. Geometry, oneway, and road metadata from planet_osm_line
            #    lanes/maxspeed/turn:lanes are not dedicated columns in the
            #    default osm2pgsql schema — pull them from the hstore tags column.
            cur.execute("""
                SELECT
                    osm_id,
                    name,
                    highway,
                    oneway,
                    tags->'lanes'               AS lanes,
                    tags->'lanes:forward'       AS lanes_forward,
                    tags->'lanes:backward'      AS lanes_backward,
                    tags->'maxspeed'            AS maxspeed,
                    tags->'turn:lanes'          AS turn_lanes,
                    tags->'turn:lanes:forward'  AS turn_lanes_forward,
                    tags->'turn:lanes:backward' AS turn_lanes_backward,
                    ST_AsText(ST_Transform(ST_StartPoint(way), 4326)) AS start_latlon,
                    ST_AsText(ST_Transform(ST_EndPoint(way),   4326)) AS end_latlon
                FROM planet_osm_line
                WHERE osm_id = %s
            """, (way_id,))
            line_row = cur.fetchone()

            # 2. Raw tags + node array from planet_osm_ways (ground truth)
            cur.execute("""
                SELECT
                    id,
                    nodes,
                    tags->>'oneway'              AS oneway_tag,
                    tags->>'lanes'               AS lanes,
                    tags->>'lanes:forward'       AS lanes_forward,
                    tags->>'lanes:backward'      AS lanes_backward,
                    tags->>'maxspeed'            AS maxspeed,
                    tags->>'highway'             AS highway,
                    tags->>'turn:lanes'          AS turn_lanes,
                    tags->>'turn:lanes:forward'  AS turn_lanes_forward,
                    tags->>'turn:lanes:backward' AS turn_lanes_backward
                FROM planet_osm_ways
                WHERE id = %s
            """, (way_id,))
            way_row = cur.fetchone()

            # 3. Ordered node coordinates
            cur.execute("""
                SELECT
                    u.ordinality,
                    n.id        AS node_id,
                    n.lat / 1e7 AS lat,
                    n.lon / 1e7 AS lon
                FROM planet_osm_ways w,
                     unnest(w.nodes) WITH ORDINALITY AS u(node_id, ordinality)
                JOIN planet_osm_nodes n ON n.id = u.node_id
                WHERE w.id = %s
                ORDER BY u.ordinality
            """, (way_id,))
            nodes = cur.fetchall()

    finally:
        conn.close()

    if to_json:
        return way_data_to_json(way_id, line_row, way_row, nodes)
    
    return line_row, way_row, nodes