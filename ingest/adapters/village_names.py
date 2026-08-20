"""Village alias table, mirroring MART.DIM_VILLAGE.ALIASES.

Duplicated here so adapters can tag documents without a database round-trip on
every parse. Keep in sync with snowflake/30_mart/dim_village.sql — the SQL table
is authoritative; this is a read-only convenience copy.

Ordered longest-alias-first at lookup time so "Great Park" is not shadowed by a
shorter substring match.
"""

from __future__ import annotations

VILLAGE_ALIASES: dict[str, str] = {
    "Woodbridge": "WOODBRIDGE",
    "Northwood": "NORTHWOOD",
    "Turtle Rock": "TURTLE_ROCK",
    "Turtle Ridge": "TURTLE_RIDGE",
    "University Park": "UNIVERSITY_PARK",
    "El Camino Real": "EL_CAMINO_REAL",
    "Culverdale": "CULVERDALE",
    "Rancho San Joaquin": "RANCHO_SAN_JOAQUIN",
    "Walnut Village": "WALNUT_VILLAGE",
    "College Park": "COLLEGE_PARK",
    "Westpark": "WESTPARK",
    "Oak Creek": "OAK_CREEK",
    "Northpark": "NORTHPARK",
    "West Irvine": "WEST_IRVINE",
    "Lower Peters Canyon": "LOWER_PETERS_CANYON",
    "Columbus Grove": "COLUMBUS_GROVE",
    "Quail Hill": "QUAIL_HILL",
    "Woodbury": "WOODBURY",
    "Portola Springs": "PORTOLA_SPRINGS",
    "Stonegate": "STONEGATE",
    "Cypress Village": "CYPRESS_VILLAGE",
    "Eastwood Village": "EASTWOOD_VILLAGE",
    "Eastwood": "EASTWOOD_VILLAGE",
    "Orchard Hills": "ORCHARD_HILLS",
    "Great Park": "GREAT_PARK",
    "Beacon Park": "GREAT_PARK",
    "Cadence Park": "GREAT_PARK",
    "Pavilion Park": "GREAT_PARK",
    "Parasol Park": "GREAT_PARK",
    "Solis Park": "GREAT_PARK",
    "Novel Park": "GREAT_PARK",
    "Laguna Altura": "LAGUNA_ALTURA",
    "Shady Canyon": "SHADY_CANYON",
    "Los Olivos": "LOS_OLIVOS",
    "Irvine Business Complex": "IBC",
    "Central Park West": "IBC",
}

# Longest first, so "Great Park" wins over a shorter incidental match.
VILLAGE_ALIASES_BY_LENGTH = dict(
    sorted(VILLAGE_ALIASES.items(), key=lambda kv: -len(kv[0]))
)
