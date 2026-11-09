## Shared catalog validation for the Godot port. The renderer will consume this in phase 2.
class_name PlanetCatalog
extends RefCounted

const PATH := "res://data/planet-catalog-100.json"
var planets: Array[Dictionary] = []

func load_catalog(path: String = PATH) -> bool:
    planets.clear()
    if not FileAccess.file_exists(path):
        push_warning("Planet catalog not bundled yet: " + path)
        return false
    var data = JSON.parse_string(FileAccess.get_file_as_string(path))
    if not (data is Dictionary) or data.get("schema") != 1 or not (data.get("planets") is Array):
        push_error("Invalid planet catalog schema")
        return false
    var names := {}
    for p in data.planets:
        if not (p is Dictionary):
            return false
        for field in ["name", "host", "ra_deg", "dec_deg", "distance_pc", "radius_earth", "period_days"]:
            if not p.has(field) or p[field] == null:
                return false
        var name := str(p.name).to_lower()
        if names.has(name):
            return false
        names[name] = true
        if float(p.radius_earth) <= 0.0 or float(p.period_days) <= 0.0 or float(p.distance_pc) <= 0.0:
            return false
        if float(p.ra_deg) < 0.0 or float(p.ra_deg) >= 360.0 or absf(float(p.dec_deg)) > 90.0:
            return false
        planets.append(p)
    return planets.size() == int(data.get("count", -1))
