#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright © 2026 Ryan Tenney.
#
# Generates the embedded data sources for the Map Home landing page:
#
#   Sources/WireGuardApp/UI/iOS/MapHome/WorldMapData.swift
#       Simplified world landmass outlines (Natural Earth 1:110m, public domain),
#       polyline-encoded at 0.1 degree precision.
#
#   Sources/WireGuardApp/UI/iOS/MapHome/MapCityDatabase.swift
#       City/country database for the endpoint location picker (Natural Earth
#       1:50m populated places, filtered to capitals + large cities + common
#       VPN hub cities).
#
#   Sources/WireGuardApp/UI/iOS/MapHome/TimeZoneLocationTable.swift
#       IANA time zone -> representative coordinates (from tzdb zone1970.tab),
#       used to approximate the user's location without any location permission.
#
# Natural Earth data is in the public domain (https://www.naturalearthdata.com).
# The tz database is public domain (https://www.iana.org/time-zones).
#
# Usage: python3 scripts/generate-map-data.py

import json
import math
import os
import ssl
import sys
import urllib.request

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT_DIR = os.path.join(REPO_ROOT, "Sources", "WireGuardApp", "UI", "iOS", "MapHome")

NE_LAND_URL = "https://raw.githubusercontent.com/nvkelso/natural-earth-vector/master/geojson/ne_110m_land.geojson"
NE_PLACES_URL = "https://raw.githubusercontent.com/nvkelso/natural-earth-vector/master/geojson/ne_50m_populated_places_simple.geojson"
NE_COUNTRIES_URL = "https://raw.githubusercontent.com/nvkelso/natural-earth-vector/master/geojson/ne_50m_admin_0_countries.geojson"
ZONETAB_URL = "https://raw.githubusercontent.com/eggert/tz/main/zone1970.tab"

# Cities that are common VPN endpoint locations but fall below the population
# cutoff in Natural Earth (or are easily missed). Matched by name.
EXTRA_CITY_NAMES = {
    "Zurich", "Geneva", "Frankfurt", "Dusseldorf", "Munich", "Hamburg",
    "Marseille", "Lyon", "Manchester", "Gothenburg", "Malmo", "Bergen",
    "Reykjavik", "Luxembourg", "Vaduz", "Monaco", "Andorra", "San Marino",
    "Salt Lake City", "Las Vegas", "Portland", "Kansas City", "St. Louis",
    "Charlotte", "Raleigh", "Nashville", "Columbus", "Indianapolis",
    "Milwaukee", "Sacramento", "San Jose", "Austin", "San Antonio",
    "Jacksonville", "Tampa", "Orlando", "Pittsburgh", "Cleveland",
    "Cincinnati", "Buffalo", "Quebec", "Ottawa", "Calgary", "Edmonton",
    "Winnipeg", "Halifax", "Perth", "Adelaide", "Brisbane", "Auckland",
    "Wellington", "Christchurch", "Osaka", "Nagoya", "Fukuoka", "Sapporo",
    "Busan", "Kaohsiung", "Cebu", "Davao", "Surabaya", "Medan", "Penang",
    "Chiang Mai", "Da Nang", "Haiphong", "Almaty", "Tashkent", "Baku",
    "Tbilisi", "Yerevan", "Minsk", "Lviv", "Odessa", "Krakow", "Wroclaw",
    "Gdansk", "Brno", "Bratislava", "Ljubljana", "Sarajevo", "Skopje",
    "Podgorica", "Tirana", "Thessaloniki", "Valencia", "Seville", "Bilbao",
    "Porto", "Bordeaux", "Toulouse", "Nice", "Turin", "Naples", "Palermo",
    "Bologna", "Florence", "Venice", "Genoa", "Rotterdam", "The Hague",
    "Eindhoven", "Antwerp", "Ghent", "Cork", "Belfast", "Edinburgh",
    "Glasgow", "Cardiff", "Leeds", "Birmingham", "Bristol", "Liverpool",
    "Fortaleza", "Recife", "Salvador", "Brasilia", "Curitiba",
    "Porto Alegre", "Belo Horizonte", "Rosario", "Cordoba", "Valparaiso",
    "Medellin", "Cali", "Guayaquil", "Arequipa", "Maracaibo", "Panama City",
    "San Salvador", "Guatemala City", "Tegucigalpa", "Managua", "San Jose",
    "Kingston", "Port-au-Prince", "Santo Domingo", "San Juan", "Nassau",
    "Bridgetown", "Casablanca", "Rabat", "Tunis", "Tripoli", "Alexandria",
    "Marrakesh", "Dakar", "Abidjan", "Kumasi", "Ibadan", "Kano", "Douala",
    "Luanda", "Lubumbashi", "Mombasa", "Kampala", "Kigali", "Lusaka",
    "Harare", "Gaborone", "Windhoek", "Maputo", "Durban", "Pretoria",
    "Port Elizabeth", "Bloemfontein", "Antananarivo", "Port Louis",
    "Doha", "Manama", "Kuwait City", "Muscat", "Abu Dhabi", "Sharjah",
    "Jeddah", "Mecca", "Medina", "Amman", "Beirut", "Damascus", "Nicosia",
    "Limassol", "Haifa", "Jerusalem", "Ankara", "Izmir", "Antalya",
    "Karachi", "Lahore", "Islamabad", "Colombo", "Kathmandu", "Thimphu",
    "Male", "Chittagong", "Yangon", "Vientiane", "Phnom Penh",
    "Ulaanbaatar", "Pyongyang", "Hyderabad", "Bangalore", "Ahmedabad",
    "Pune", "Kolkata", "Chennai", "Surat", "Kanpur", "Nagpur",
}

# Natural Earth uses -99 for some ISO codes; patch the well-known cases.
ISO_A2_PATCHES = {
    "FRA": "FR", "France": "FR",
    "NOR": "NO", "Norway": "NO",
    "KOS": "XK", "Kosovo": "XK",
    "SDS": "SS", "South Sudan": "SS",
    "SOL": "SO", "Somaliland": "SO",
    "CYN": "CY", "Northern Cyprus": "CY",
    "TWN": "TW", "Taiwan": "TW",
}

SWIFT_HEADER = """// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright © 2026 Ryan Tenney.
//
// GENERATED FILE - DO NOT EDIT BY HAND.
// Regenerate with: python3 scripts/generate-map-data.py
"""


def fetch(url):
    print("Fetching %s" % url)
    ctx = ssl.create_default_context()
    ca_bundle = os.environ.get("SSL_CERT_FILE") or "/root/.ccr/ca-bundle.crt"
    if os.path.exists(ca_bundle):
        ctx.load_verify_locations(ca_bundle)
    req = urllib.request.Request(url, headers={"User-Agent": "wgnext-map-data-generator"})
    with urllib.request.urlopen(req, context=ctx, timeout=120) as resp:
        return resp.read()


# ---------------------------------------------------------------------------
# Geometry helpers
# ---------------------------------------------------------------------------

def perpendicular_distance(pt, a, b):
    ax, ay = a
    bx, by = b
    px, py = pt
    dx, dy = bx - ax, by - ay
    if dx == 0 and dy == 0:
        return math.hypot(px - ax, py - ay)
    t = ((px - ax) * dx + (py - ay) * dy) / (dx * dx + dy * dy)
    t = max(0.0, min(1.0, t))
    cx, cy = ax + t * dx, ay + t * dy
    return math.hypot(px - cx, py - cy)


def douglas_peucker(points, epsilon):
    if len(points) < 3:
        return points
    # Iterative stack-based implementation to avoid recursion limits.
    keep = [False] * len(points)
    keep[0] = keep[-1] = True
    stack = [(0, len(points) - 1)]
    while stack:
        start, end = stack.pop()
        max_dist = 0.0
        index = -1
        for i in range(start + 1, end):
            d = perpendicular_distance(points[i], points[start], points[end])
            if d > max_dist:
                max_dist = d
                index = i
        if index != -1 and max_dist > epsilon:
            keep[index] = True
            stack.append((start, index))
            stack.append((index, end))
    return [p for p, k in zip(points, keep) if k]


def ring_area(points):
    # Shoelace, in square degrees (approximate; good enough for filtering).
    area = 0.0
    n = len(points)
    for i in range(n):
        x1, y1 = points[i]
        x2, y2 = points[(i + 1) % n]
        area += x1 * y2 - x2 * y1
    return abs(area) / 2.0


# ---------------------------------------------------------------------------
# Polyline encoding (Google encoded polyline algorithm)
# ---------------------------------------------------------------------------

def encode_value(value, output):
    value = value << 1
    if value < 0:
        value = ~value
    while value >= 0x20:
        output.append(chr((0x20 | (value & 0x1F)) + 63))
        value >>= 5
    output.append(chr(value + 63))


def encode_polyline(points, precision):
    factor = 10 ** precision
    output = []
    prev_lat, prev_lon = 0, 0
    for lon, lat in points:
        ilat = int(round(lat * factor))
        ilon = int(round(lon * factor))
        encode_value(ilat - prev_lat, output)
        encode_value(ilon - prev_lon, output)
        prev_lat, prev_lon = ilat, ilon
    return "".join(output)


def decode_polyline(text, precision):
    factor = 10 ** precision
    points = []
    index, lat, lon = 0, 0, 0
    while index < len(text):
        for is_lon in (False, True):
            shift, result = 0, 0
            while True:
                b = ord(text[index]) - 63
                index += 1
                result |= (b & 0x1F) << shift
                shift += 5
                if b < 0x20:
                    break
            delta = ~(result >> 1) if (result & 1) else (result >> 1)
            if is_lon:
                lon += delta
            else:
                lat += delta
        points.append((lon / factor, lat / factor))
    return points


def swift_escape(text):
    return text.replace("\\", "\\\\").replace('"', '\\"')


# ---------------------------------------------------------------------------
# Land polygons
# ---------------------------------------------------------------------------

def generate_land(out_path):
    geo = json.loads(fetch(NE_LAND_URL))
    rings = []
    for feature in geo["features"]:
        geom = feature["geometry"]
        if geom["type"] == "Polygon":
            polys = [geom["coordinates"]]
        elif geom["type"] == "MultiPolygon":
            polys = geom["coordinates"]
        else:
            continue
        for poly in polys:
            for ring in poly:
                rings.append([(float(x), float(y)) for x, y in ring])

    epsilon = 0.18
    min_area = 0.45  # square degrees; drops specks that render < 2px
    encoded = []
    total_points = 0
    kept = 0
    for ring in rings:
        if ring_area(ring) < min_area:
            continue
        simplified = douglas_peucker(ring, epsilon)
        # Quantize to 0.1 degrees and drop consecutive duplicates.
        quantized = []
        for lon, lat in simplified:
            q = (round(lon, 1), round(lat, 1))
            if not quantized or quantized[-1] != q:
                quantized.append(q)
        if len(quantized) >= 2 and quantized[0] == quantized[-1]:
            quantized.pop()
        if len(quantized) < 4:
            continue
        line = encode_polyline(quantized, 1)
        assert decode_polyline(line, 1) == [(round(x, 1), round(y, 1)) for x, y in quantized]
        encoded.append(line)
        total_points += len(quantized)
        kept += 1

    print("Land: kept %d rings, %d points" % (kept, total_points))
    # Backslash is part of the polyline alphabet; escape it for the Swift
    # string literal (quotes cannot occur: the alphabet is ASCII 63-126).
    payload = swift_escape("\n".join(encoded))

    swift = SWIFT_HEADER + """//
// World landmass outlines from Natural Earth 1:110m (public domain),
// simplified and polyline-encoded at 0.1 degree precision.
// %d rings, %d points.

import CoreGraphics

enum WorldMapData {

    /// Decoded landmass rings. Each ring is a closed polygon of
    /// (longitude, latitude) pairs in degrees.
    static let landRings: [[CGPoint]] = encodedRings.split(separator: "\\n").map { decodePolyline(String($0)) }

    /// Decodes one Google-encoded polyline (precision 1, i.e. 0.1 degrees)
    /// into (longitude, latitude) points.
    private static func decodePolyline(_ text: String) -> [CGPoint] {
        var points = [CGPoint]()
        var lat = 0
        var lon = 0
        var index = text.startIndex

        while index < text.endIndex {
            var deltas = [Int, Int](repeating: 0, count: 2)
            for component in 0 ..< 2 {
                var shift = 0
                var result = 0
                while true {
                    let byte = Int(text[index].asciiValue ?? 63) - 63
                    index = text.index(after: index)
                    result |= (byte & 0x1F) << shift
                    shift += 5
                    if byte < 0x20 { break }
                }
                deltas[component] = (result & 1) != 0 ? ~(result >> 1) : (result >> 1)
            }
            lat += deltas[0]
            lon += deltas[1]
            points.append(CGPoint(x: Double(lon) / 10.0, y: Double(lat) / 10.0))
        }
        return points
    }

    private static let encodedRings = \"\"\"
%s
\"\"\"
}
""" % (kept, total_points, payload)
    # The template above intentionally can't express [Int](repeating:) cleanly
    # via %-format; patch the placeholder.
    swift = swift.replace("[Int, Int](repeating: 0, count: 2)", "[Int](repeating: 0, count: 2)")
    with open(out_path, "w") as f:
        f.write(swift)
    print("Wrote %s (%d KB)" % (out_path, len(swift) // 1024))


# ---------------------------------------------------------------------------
# City database
# ---------------------------------------------------------------------------

def generate_cities(out_path):
    countries = json.loads(fetch(NE_COUNTRIES_URL))
    iso2_by_a3 = {}
    name_by_a3 = {}
    for feature in countries["features"]:
        props = feature["properties"]
        a3 = props.get("ADM0_A3") or props.get("adm0_a3")
        iso2 = props.get("ISO_A2") or props.get("iso_a2")
        name = props.get("NAME") or props.get("name")
        if not a3:
            continue
        if not iso2 or iso2 == "-99":
            iso2 = ISO_A2_PATCHES.get(a3) or ISO_A2_PATCHES.get(name or "", "")
        if iso2:
            iso2_by_a3[a3] = iso2
        if name:
            name_by_a3[a3] = name

    places = json.loads(fetch(NE_PLACES_URL))
    rows = []
    seen = set()
    for feature in places["features"]:
        props = feature["properties"]
        name = props.get("name") or ""
        adm0_a3 = props.get("adm0_a3") or props.get("sov_a3") or ""
        country = props.get("adm0name") or name_by_a3.get(adm0_a3, "")
        featurecla = (props.get("featurecla") or "").lower()
        pop = props.get("pop_max") or 0
        lon = feature["geometry"]["coordinates"][0]
        lat = feature["geometry"]["coordinates"][1]

        is_capital = "admin-0 capital" in featurecla
        is_big = pop >= 1000000
        is_extra = name in EXTRA_CITY_NAMES
        if not (is_capital or is_big or is_extra):
            continue

        iso2 = iso2_by_a3.get(adm0_a3, "") or ISO_A2_PATCHES.get(country, "")
        if not iso2:
            continue
        if country == "United States of America":
            country = "United States"
        if "|" in name or "|" in country:
            continue
        key = (name, iso2)
        if key in seen:
            continue
        seen.add(key)
        rows.append((name, country, iso2, lat, lon))

    rows.sort(key=lambda r: (r[0], r[1]))
    lines = ["%s|%s|%s|%.2f|%.2f" % (swift_escape(n), swift_escape(c), i, lat, lon)
             for n, c, i, lat, lon in rows]
    print("Cities: %d entries" % len(rows))

    swift = SWIFT_HEADER + """//
// City database for the endpoint location picker, from Natural Earth 1:50m
// populated places (public domain): capitals, cities over 1M population,
// and common VPN hub cities. %d entries.

import Foundation

enum MapCityDatabase {

    /// All known cities, sorted by name.
    static let cities: [MapCity] = records.split(separator: "\\n").compactMap { line in
        let fields = line.split(separator: "|", omittingEmptySubsequences: false)
        guard fields.count == 5,
              let latitude = Double(fields[3]),
              let longitude = Double(fields[4]) else { return nil }
        return MapCity(name: String(fields[0]),
                       country: String(fields[1]),
                       countryCode: String(fields[2]),
                       latitude: latitude,
                       longitude: longitude)
    }

    private static let records = \"\"\"
%s
\"\"\"
}

struct MapCity {
    let name: String
    let country: String
    let countryCode: String
    let latitude: Double
    let longitude: Double
}
""" % (len(rows), "\n".join(lines))
    with open(out_path, "w") as f:
        f.write(swift)
    print("Wrote %s (%d KB)" % (out_path, len(swift) // 1024))


# ---------------------------------------------------------------------------
# Time zone table
# ---------------------------------------------------------------------------

def parse_iso6709(coord):
    # +DDMM+DDDMM or +DDMMSS+DDDMMSS
    sign2 = coord.rfind("+", 1)
    sign3 = coord.rfind("-", 1)
    split = max(sign2, sign3)
    lat_s, lon_s = coord[:split], coord[split:]

    def parse(s, deg_digits):
        sign = -1.0 if s[0] == "-" else 1.0
        body = s[1:]
        deg = int(body[:deg_digits])
        minutes = int(body[deg_digits:deg_digits + 2]) if len(body) >= deg_digits + 2 else 0
        seconds = int(body[deg_digits + 2:deg_digits + 4]) if len(body) >= deg_digits + 4 else 0
        return sign * (deg + minutes / 60.0 + seconds / 3600.0)

    return parse(lat_s, 2), parse(lon_s, 3)


def generate_timezones(out_path):
    text = fetch(ZONETAB_URL).decode("utf-8")
    rows = []
    for line in text.splitlines():
        if not line or line.startswith("#"):
            continue
        parts = line.split("\t")
        if len(parts) < 3:
            continue
        coord, tz_name = parts[1], parts[2]
        try:
            lat, lon = parse_iso6709(coord)
        except (ValueError, IndexError):
            continue
        rows.append((tz_name, lat, lon))

    rows.sort(key=lambda r: r[0])
    lines = ["%s|%.2f|%.2f" % (n, lat, lon) for n, lat, lon in rows]
    print("Time zones: %d entries" % len(rows))

    swift = SWIFT_HEADER + """//
// IANA time zone identifiers -> representative coordinates, from the tz
// database's zone1970.tab (public domain). Used to approximate the user's
// location without requesting any location permission. %d entries.

import Foundation

enum TimeZoneLocationTable {

    /// Representative (latitude, longitude) for a time zone identifier, or
    /// a rough longitude estimated from the GMT offset when unknown.
    static func coordinates(for timeZone: TimeZone) -> (latitude: Double, longitude: Double) {
        if let found = locationsByIdentifier[timeZone.identifier] {
            return found
        }
        let offsetHours = Double(timeZone.secondsFromGMT()) / 3600.0
        return (latitude: 20.0, longitude: max(-180.0, min(180.0, offsetHours * 15.0)))
    }

    private static let locationsByIdentifier: [String: (latitude: Double, longitude: Double)] = {
        var table = [String: (latitude: Double, longitude: Double)]()
        for line in records.split(separator: "\\n") {
            let fields = line.split(separator: "|")
            guard fields.count == 3,
                  let latitude = Double(fields[1]),
                  let longitude = Double(fields[2]) else { continue }
            table[String(fields[0])] = (latitude: latitude, longitude: longitude)
        }
        return table
    }()

    private static let records = \"\"\"
%s
\"\"\"
}
""" % (len(rows), "\n".join(lines))
    with open(out_path, "w") as f:
        f.write(swift)
    print("Wrote %s (%d KB)" % (out_path, len(swift) // 1024))


def main():
    os.makedirs(OUT_DIR, exist_ok=True)
    generate_land(os.path.join(OUT_DIR, "WorldMapData.swift"))
    generate_cities(os.path.join(OUT_DIR, "MapCityDatabase.swift"))
    generate_timezones(os.path.join(OUT_DIR, "TimeZoneLocationTable.swift"))
    print("Done.")


if __name__ == "__main__":
    sys.exit(main())
