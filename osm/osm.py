import math

def interpret_oneway(oneway_value):
    if oneway_value in ("yes", "1", "true"):
        return "ONE-WAY (forward) - travel follows node order"
    elif oneway_value == "-1":
        return "ONE-WAY (reverse) - travel goes AGAINST node order"
    elif oneway_value in ("no", "0", "false"):
        return "TWO-WAY - bidirectional travel"
    elif oneway_value is None:
        return "TWO-WAY - bidirectional travel (oneway tag absent)"
    else:
        return f"UNKNOWN oneway value: '{oneway_value}'"


def compute_bearing(lat1, lon1, lat2, lon2) -> float:
    """Forward azimuth from (lat1,lon1) to (lat2,lon2). Returns 0–360°."""
    lat1, lon1, lat2, lon2 = map(math.radians, [lat1, lon1, lat2, lon2])
    d_lon = lon2 - lon1
    x = math.sin(d_lon) * math.cos(lat2)
    y = math.cos(lat1) * math.sin(lat2) - math.sin(lat1) * math.cos(lat2) * math.cos(d_lon)
    return math.degrees(math.atan2(x, y)) % 360


def bearing_to_compass(bearing: float) -> str:
    """Map 0–360° bearing to one of 8 compass points."""
    directions = ["N", "NE", "E", "SE", "S", "SW", "W", "NW"]
    return directions[int((bearing + 22.5) / 45) % 8]


# ---------------------------------------------------------------------------
# Metadata helpers
# ---------------------------------------------------------------------------

def coalesce(*values):
    """Return the first non-None, non-empty value."""
    for v in values:
        if v is not None and str(v).strip() != "":
            return str(v).strip()
    return None


def format_turn_lanes(turn_lanes_str):
    """
    Parse a turn:lanes value like 'left|through|through|right'
    and render it as a lane-by-lane list.
    """
    if not turn_lanes_str:
        return None
    lanes = turn_lanes_str.split("|")
    return [f"  Lane {i+1}: {l if l else '(none/unspecified)'}"
            for i, l in enumerate(lanes)]


def parse_turn_lanes(turn_lanes_str):
    """Parse 'left|through|right' into a list of lane strings."""
    if not turn_lanes_str:
        return None
    return [l if l else None for l in turn_lanes_str.split("|")]
 
 
 
def parse_point(wkt: str) -> dict:
    """Convert 'POINT(lon lat)' WKT string to {lat, lon} dict of floats."""
    if not wkt:
        return None
    # WKT from ST_AsText is "POINT(lon lat)"
    coords = wkt.strip().removeprefix("POINT(").removesuffix(")").split()
    return {"lon": float(coords[0]), "lat": float(coords[1])}
 
def way_data_to_json(way_id, line_row, way_row, nodes) -> dict:
    """Return all way data as a structured dict (JSON-serialisable)."""
    if not way_row and not line_row:
        return {"way_id": way_id, "found": False}
 
    # --- Basic identity ---
    oneway_raw = coalesce(
        way_row  and way_row["oneway_tag"],
        line_row and line_row["oneway"],
    )
    oneway_norm = (oneway_raw or "").lower()
    highway = coalesce(
        line_row and line_row["highway"],
        way_row  and way_row["highway"],
    )
 
    # --- Road metadata ---
    lanes          = coalesce(way_row and way_row["lanes"],               line_row and line_row["lanes"])
    lanes_fwd      = coalesce(way_row and way_row["lanes_forward"],       line_row and line_row["lanes_forward"])
    lanes_bwd      = coalesce(way_row and way_row["lanes_backward"],      line_row and line_row["lanes_backward"])
    maxspeed       = coalesce(way_row and way_row["maxspeed"],            line_row and line_row["maxspeed"])
    turn_lanes     = coalesce(way_row and way_row["turn_lanes"],          line_row and line_row["turn_lanes"])
    turn_lanes_fwd = coalesce(way_row and way_row["turn_lanes_forward"],  line_row and line_row["turn_lanes_forward"])
    turn_lanes_bwd = coalesce(way_row and way_row["turn_lanes_backward"], line_row and line_row["turn_lanes_backward"])

    if lanes:
        lanes = int(lanes.strip())
    if lanes_fwd:
        lanes_fwd = int(lanes_fwd.strip())
    if lanes_bwd:
        lanes_bwd = int(lanes_bwd.strip())
 
    # maxspeed unit inference
    maxspeed_unit = None
    if maxspeed:
        parts = maxspeed.split()
        if len(parts) == 2:
            maxspeed_unit = parts[1]        # e.g. "mph" from "30 mph"
        elif maxspeed.isdigit():
            maxspeed_unit = "mph"          # OSM convention: bare number = mph
        maxspeed = int(parts[0])
 
    # --- Geometry ---
    geometry = None
    if line_row:
        geometry = {
            "start": parse_point(line_row["start_latlon"]),
            "end":   parse_point(line_row["end_latlon"]),
        }
 
    # --- Direction ---
    direction_type = None
    if oneway_norm in ("yes", "1", "true"):
        direction_type = "one_way_forward"
    elif oneway_norm == "-1":
        direction_type = "one_way_reverse"
    else:
        direction_type = "two_way"
 
    travel_direction = {
        "type":        direction_type,
        "description": interpret_oneway(oneway_raw),
    }
    if nodes:
        first, last = nodes[0], nodes[-1]
        if direction_type == "one_way_forward":
            travel_direction["from"] = {"lat": float(first["lat"]), "lon": float(first["lon"]), "node_id": first["node_id"]}
            travel_direction["to"]   = {"lat": float(last["lat"]),  "lon": float(last["lon"]),  "node_id": last["node_id"]}
        elif direction_type == "one_way_reverse":
            travel_direction["from"] = {"lat": float(last["lat"]),  "lon": float(last["lon"]),  "node_id": last["node_id"]}
            travel_direction["to"]   = {"lat": float(first["lat"]), "lon": float(first["lon"]), "node_id": first["node_id"]}
        else:
            travel_direction["forward"] = {
                "from": {"lat": float(first["lat"]), "lon": float(first["lon"]), "node_id": first["node_id"]},
                "to":   {"lat": float(last["lat"]),  "lon": float(last["lon"]),  "node_id": last["node_id"]},
            }
            travel_direction["backward"] = {
                "from": {"lat": float(last["lat"]),  "lon": float(last["lon"]),  "node_id": last["node_id"]},
                "to":   {"lat": float(first["lat"]), "lon": float(first["lon"]), "node_id": first["node_id"]},
            }
 
    # --- Compass bearing ---
    compass = None
    if nodes and len(nodes) >= 2:
        first, last = nodes[0], nodes[-1]
        fwd_bearing = compute_bearing(first["lat"], first["lon"], last["lat"], last["lon"])
        fwd_compass = bearing_to_compass(fwd_bearing)
        rev_bearing = (fwd_bearing + 180) % 360
        rev_compass = bearing_to_compass(rev_bearing)
 
        if direction_type == "one_way_forward":
            compass = {"bearing_deg": round(fwd_bearing, 1), "direction": fwd_compass}
        elif direction_type == "one_way_reverse":
            compass = {"bearing_deg": round(rev_bearing, 1), "direction": rev_compass}
        else:
            compass = {
                "forward":  {"bearing_deg": round(fwd_bearing, 1), "direction": fwd_compass},
                "backward": {"bearing_deg": round(rev_bearing, 1), "direction": rev_compass},
            }
 
    # --- Node sequence ---
    node_list = [
        {
            "sequence":  int(n["ordinality"]),
            "node_id":   int(n["node_id"]),
            "lat":       round(float(n["lat"]), 7),
            "lon":       round(float(n["lon"]), 7),
        }
        for n in nodes
    ] if nodes else []
 
    return {
        "way_id":   way_id,
        "found":    True,
        "identity": {
            "name":    coalesce(line_row and line_row["name"]),
            "highway": highway,
            "oneway":  True if oneway_raw == "yes" else False,
        },
        "road_metadata": {
            "lanes": {
                "total":    lanes,
                "forward":  lanes_fwd,
                "backward": lanes_bwd,
            },
            "maxspeed": {
                "value": maxspeed,
                "unit":  maxspeed_unit,
            },
            "turn_lanes": {
                "general":  {
                    "raw":    turn_lanes,
                    "parsed": parse_turn_lanes(turn_lanes),
                },
                "forward":  {
                    "raw":    turn_lanes_fwd,
                    "parsed": parse_turn_lanes(turn_lanes_fwd),
                },
                "backward": {
                    "raw":    turn_lanes_bwd,
                    "parsed": parse_turn_lanes(turn_lanes_bwd),
                },
            },
        },
        "geometry":         geometry,
        "travel_direction": travel_direction,
        "compass":          compass,
        "nodes":            node_list,
    }
