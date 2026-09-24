ISS reference: Python sgp4 2.27, Satrec/OMM, WGS72, default improved mode, using the identical ISS GP record. Dates span ±1 day around epoch. TEME kilometers and km/s.

Vallado fixtures: aholinch/sgp4 commit 552cb1489a52c3023ae70cb6c7e239e84c5950fe, data/sgp4-ver.json and sgp4-ver.out.json. Input TLE fields were converted losslessly to OMM keywords. Reference outputs are unchanged. Includes Vanguard 1, near-Earth 6251, GEO 24208, and Molniya 8195. Unlicense; see Vendor/CSGP4/LICENSE.

`satellite-seeds.json` contains CelesTrak JSON GP snapshots for NORAD 25544, 48274, 20580, and 43013, retrieved September 23, 2026. Each record includes its original element epoch and download time. Used to validate catalog identity, propagation, and cache separation.
