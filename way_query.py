#!/usr/bin/env python3
"""
osm_way_direction.py
Given an OSM way ID, prints direction(s) of travel, compass heading,
and road metadata (lanes, maxspeed, highway type, turn:lanes).

Usage:
    python way_query.py <way_id>
"""

import sys
import json

import psycopg2

from osm.query import way_data_by_way_id

def main():
    if len(sys.argv) < 2 or len(sys.argv) > 3:
        print(f"Usage: python {sys.argv[0]} <way_id> [--to_json]")
        sys.exit(1)

    try:
        way_id = int(sys.argv[1])
    except ValueError:
        print(f"[!] way_id must be an integer, got: {sys.argv[1]!r}")
        sys.exit(1)

    to_json = False
    try:
        to_json_raw = sys.argv[2]
        if to_json_raw.strip() == "--to_json":
            to_json = True
    except:
        pass

    try:
        way_json = way_data_by_way_id(way_id, True)
    except psycopg2.OperationalError as e:
        print(f"[!] Could not connect to database: {e}")
        sys.exit(1)
    except psycopg2.Error as e:
        print(f"[!] Database error: {e}")
        sys.exit(1)

    if to_json:
        with open(f"{way_id}.json", "w") as f:
            json.dump(way_json, f, indent=4)
    else:
        print(json.dumps(way_json, indent=4))


if __name__ == "__main__":
    main()