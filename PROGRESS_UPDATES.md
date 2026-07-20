# Spatial Data Progress Updates

This file records material changes to the spatial data after the March 25, 2025 AppEEARS/NASA extract. It distinguishes new site rows from existing sites that received corrected geometry or filled driver years.

## Current accepted products

- Wide AppEEARS/NASA extract: `appeears_spatial-extract_524sites_20260720.csv` — 524 sites, 401 columns.
- Watershed package: `silica_gee_watersheds_524sites_20260719.gpkg` — 524 unique site IDs, no empty or invalid geometry, and no MCM channel polygons.
- Watershed upload package: `silica_gee_watersheds_524sites_20260719_shapefile.zip`.
- Current Box locations:
  - `spatial-data-files/appeears-nasa/`
  - `spatial-data-files/gee/`
  - `spatial-data-files/harmonization-variables/`
  - `silica-shapefiles/`

## Dataset checkpoints

| Date | File or package | Site accounting | Material change |
|---|---|---:|---|
| 2025-03-25 | `all-data_si-extract_2_20250325.csv` | 570 rows; 497 unique normalized LTER/stream names; 367 columns | Baseline used for this change log. The file is retained with the archived GRL submission inputs. |
| 2026-06-29 | `all-data_si-extract_3_20260629.csv` | 543 unique site rows; 401 columns | Consolidated May-June reruns and new site records. Seventy row identifiers were not in the March baseline after matching both stream and discharge identifiers. March duplicate and alias rows were collapsed. |
| 2026-07-14 | `all-data_si-extract_3_20260629_with_coast_distance.csv` | 543 | Added distance-to-coast values; no site rows were added. |
| 2026-07-16 | `all-data_si-extract_3_20260716.csv` | 543 | Added targeted AppEEARS results for Andrews Creek, Serrinha, KRR S65B, and DMF Brazos River; no site rows were added. |
| 2026-07-17 | `all-data_si-extract_3_20260717.csv` | 543 | Filled ET and snow gaps for 22 sites; no site rows were added. |
| 2026-07-18 | `all-data_si-extract_3_20260718_unfiltered_intermediate.csv` | 548 | Added five newly recovered watershed sites and their AppEEARS results. |
| 2026-07-19 | `all-data_si-extract_3_20260719.csv` | 524 | Restricted the final all-spatial file to sites with accepted watershed geometry. Twenty-four rows without an accepted watershed were removed. |
| 2026-07-20 | `appeears_spatial-extract_524sites_20260720.csv` | 524 | Ran the usual snow and permafrost checks for the five recently added sites. Fitzroy Crossing snow was set to zero, and missing permafrost values were set to zero for Fitzroy Crossing and the four new LMP sites. |

## 2026-05-08 to 2026-05-24: HydroSHEDS review and May additions

- Standardized HydroSHEDS upstream-ID handling and retained HydroSHEDS sites in targeted rerun planning.
- The May 14 review approved full-record HydroSHEDS work for Cameroon Mbalmayo, Messam, Olama, and Pont So'o, plus newer-year updates for six Canada sites and nine Murray-Darling sites. Sites not meeting the watershed-size or downstream-use rules were held.
- The May 23 land-cover pull covered 48 identifiers. Forty-seven names were absent from the March file; Yampa River Below Craig was an existing site included in the pull.
- The May additions used already supplied project watershed files, reprojected copies of those files, or accepted HydroSHEDS geometry. They included:
  - Amazon: Amazon River at Itapeua, Manacapuru, Santo Antonio do Ica, and Vargem Grande; Rio Ica, Japura, Jurua, Jutai, Madeira, Negro, and Purus. These use Glorich watershed files retained under `silica-shapefiles/reprojected/`.
  - ColoradoAlpine: Loch. Its accepted source was later documented as the Loch Vale Watershed Study file `lvws_basin`.
  - Congo Basin: Mbalmayo, Messam, Olama, and Pont So'o. These use the supplied Nyong, Awout, and Soo watershed files retained under `silica-shapefiles/reprojected/`.
  - EastRiverSFA: `ce_cmt0`, `coal_11`, `er_brd1`, `er_cpr1`, `er_eaq1`, `er_ebc1`, `er_phf0`, `er_rck1`, `er_rus1`, `lo_loc1`, `sg_suf1`, and `tr_tcg1`. These use project-supplied watershed files retained under `silica-shapefiles/artisanal-shapefiles-2/`.
  - Guadeloupe: Capesterre, La Digue; Maison de la Forêt; Petit Bras-David; Ravine Quiock; Vieux-Habitants, Barthole; and Vieux-Habitants, Savanne-Beauséjour. These use supplied BD CARTHAGE watershed-zone files.
  - MD: Barham and Jingellic, using `AUS_409005` and `AUS_401201`.
  - NWT: `como`, using the existing Como Creek polygon. This is an alias of NWT Como Creek, not a new physical watershed.
  - Seine: Amfreville-sous-les-Monts, Bennecourt, Carrieres-sous-Poissy, Ivry-sur-Seine, Paris-12e--Arrondissement, Poses 3, and Triel-sur-Seine, using project-supplied watershed files.
  - USGS: Arkansas River at Murray Dam, Columbia River at Port Westward, and North Sylamore. North Sylamore was later replaced with a site-specific NLDI whole-basin polygon.
- EastRiverSFA `coal_11` is the same physical site and geometry as the older Coal Creek row. Both identifiers remain in the current 524-row product and must not be interpreted as two independent watersheds.

## By 2026-06-29: remaining rows added after March

The June 29 file also contained 23 row identifiers not represented in the May 23 land-cover pull:

- ARC: Imnavait Upper, Imnavait WT 07 Weir, Toolik Inlet, and TW Weir.
- ColoradoAlpine: Andrews Creek.
- Congo Basin: Nsimi Outlet and Nsimi Spring.
- GRO: Obidos.
- HYBAM: Fazenda Vista Alegre, Labrea, Obidos, Serrinha, and Tabatinga.
- KRR: S65B and S65C.
- LMP: NOR27.
- LUQ: QP.
- MCM: Andersen Creek at H1, Lawson Creek at B3, Onyx River at Lake Vanda Weir, Onyx River at Lower Wright Weir, and Priscu Stream at B1.
- USGS: DMF Brazos River.

Several of these were row additions before a defensible watershed had been found. ARC, the Nsimi sites, HYBAM Obidos, LUQ QP, the five MCM sites, and KRR S65B were later removed from the final all-spatial file. The accepted geometry recoveries are listed below.

## 2026-07-15: recovered and documented polygons

| Site | Living-table `Shapefile_Name` | Accepted source | HydroSHEDS? | Final status |
|---|---|---|---|---|
| ColoradoAlpine — Andrews Creek | `andrews_nldi` | USGS NLDI whole-basin polygon | No | Retained |
| ColoradoAlpine — Loch | `lvws_basin` | Loch Vale Watershed Study spatial data | No | Retained |
| HYBAM — Labrea | `labrea_hydrosheds` | HydroBASINS v1c upstream union; outlet `6120400480` | Yes | Retained |
| HYBAM — Serrinha | `serrinha_hydrosheds` | HydroBASINS v1c upstream union; outlet `6120218550` | Yes | Retained |
| HYBAM — Tabatinga | `tabatinga_hydrosheds` | HydroBASINS v1c upstream union; outlet `6120313630` | Yes | Retained |
| LMP — NOR27 | `nor27_nldi` | USGS NLDI whole-basin polygon | No | Retained |
| USGS — DMF Brazos River | `dmf_brazos_river_gagesii` | USGS GAGES-II basin for gage 08079600 | No | Retained |
| USGS — North Sylamore | `north_sylamore_nldi` | USGS NLDI whole-basin polygon | No | Retained |

The targeted AppEEARS work used the corrected polygons for Andrews Creek, Serrinha, and DMF Brazos River. KRR S65B was also run at this stage but was later removed because `s_65bc` is a combined S-65BC management area, not a unique S65B watershed.

## 2026-07-16 to 2026-07-17: corrected geometry and driver backfills

- Fazenda Vista Alegre was corrected from the wrong `rio_madeira` polygon to `fazenda_vista_alegre_hydrosheds`, a HydroBASINS v1c upstream union with outlet `6120330250`. Polygon area is 1,314,827.1 km² versus 1,317,760 km² in the reference table, a -0.223% difference.
- KRR `s_65bc` is a supplied SFWMD combined management-basin polygon. The current final product retains it once under S65C and removes S65B. This does not establish a unique S65C watershed; it avoids using the same combined area twice.
- AppEEARS ET and snow corrections filled or replaced 125 cells for 22 sites:
  - Six Guadeloupe sites: Capesterre, La Digue; Maison de la Forêt; Petit Bras-David; Ravine Quiock; Vieux-Habitants, Barthole; Vieux-Habitants, Savanne-Beauséjour.
  - LUQ RES4.
  - HYBAM Fazenda Vista Alegre, Labrea, and Tabatinga.
  - KRR S65C.
  - Seven Seine sites: Amfreville-sous-les-Monts, Bennecourt, Carrieres-sous-Poissy, Ivry-sur-Seine, Paris-12e--Arrondissement, Poses 3, and Triel-sur-Seine.
  - Congo Basin Olama and Pont So'o.
  - LMP NOR27.
  - USGS Hillabahatchie Creek/FRAN for 2021 snow.
- After this update, all 22 corrected sites had complete ET, NPP, cycle-0 green-up, snow-day, and maximum snow-area fields for 2002-2022.

## 2026-07-17 to 2026-07-19: five newly accepted sites

| Site | Living-table `Shapefile_Name` | Source and check | HydroSHEDS? |
|---|---|---|---|
| LMP — LTR20 | `ltr20_nldi` | USGS NLDI COMID 5848028; 49.279 km² versus 51.7 km² reference | No |
| LMP — NBR12 | `nbr12_nldi` | USGS NLDI COMID 5848142; 44.568 km² versus 41.5 km² reference | No |
| LMP — PWT03 | `pwt03_nldi` | USGS NLDI COMID 5848050; 2.968 km² versus 2.6 km² reference | No |
| LMP — RMB04 | `rmb04_nldi` | USGS NLDI COMID 5848152; 4.913 km² versus 4.9 km² reference | No |
| WesternAustralia — Fitzroy River — Fitzroy Crossing | `fitzroy_river_fitzroy_crossing_bom_geofabric` | Bureau of Meteorology Geofabric V3.3 station catchment for gauge 802055; 45,627.002 km² | No |

- All five polygons contain their outlet, are valid, and are not exact duplicates of an accepted geometry.
- Fitzroy Crossing must use the official gauge coordinate: longitude 125.5783, latitude -18.20972.
- The five source bundles and their source README are retained in `silica-shapefiles/recovered-20260717/`.
- The five AppEEARS requests were downloaded, extracted, combined, and included in the July 18 intermediate.

## 2026-07-19: final geometry filter

The 548-row intermediate was reduced to 524 sites by removing rows without an accepted watershed:

- Four ARC sites: Imnavait Upper, Imnavait WT 07 Weir, Toolik Inlet, and TW Weir.
- Congo Basin Nsimi Outlet and Nsimi Spring.
- HYBAM Obidos; GRO Obidos is the retained cross-network Obidos row.
- KRR S65B; S65C is the single retained representative of the combined `s_65bc` management area.
- LUQ QP; its NLDI candidate was 3.32 km² versus the 0.31 km² reference area and was rejected.
- All 15 MCM rows. Ten had stream-channel polygons rather than watershed polygons, and five had no accepted watershed. No MCM row remains in the final product.

The following duplicated sites or shared watershed areas are documented and
should not be treated as independent watersheds: NWT Como/Como Creek, Seine
Carrieres-sous-Poissy/Triel-sur-Seine, the three Kymijoki rows, Coal
Creek/EastRiverSFA `coal_11`, and Guadeloupe Barthole/Savanne-Beauséjour. KJ
and Sidney will review these cases at the July 21 data check-in.

## 2026-07-20: corrected snow and permafrost values

- The five sites added on July 18 had missed the earlier snow and permafrost
  checks, so the same checks were run before accepting the final file.
- Fitzroy Crossing is a warm, low-elevation tropical watershed. Its apparent
  snow values were false, so all Fitzroy snow fields were set to zero.
- Permafrost was set to zero for Fitzroy Crossing and the four new LMP sites.
- The LMP snow values were kept because those sites did not meet the rule for
  automatically setting snow to zero.
- This fixed 92 cells without adding or removing any sites. The AppEEARS QA
  plots were then rebuilt.
- The correction code and change log are produced by
  `tools/apply_spatial_domain_filters.R`.

## Current QA notes

- Required AppEEARS coverage for 2002-2022 is complete for 521 of 524 sites.
- Cycle-0 green-up values are still missing for Catalina Jemez BGZOB_FLUME
  (2002, 2003, 2004, 2007, 2011, 2012, and 2021), Catalina Jemez OR_low
  (2002), and Andrews Creek (2003, 2008, and 2012). These years were rerun;
  MODIS did not return usable values. Cycle 1 is optional.
- Ravine Quiock's accepted BD CARTHAGE polygon is 9.76 km² while the reference table says 0.78 km². A square-mile conversion does not resolve the discrepancy: 0.78 mi² is about 2.02 km². The reference drainage area needs review.
- Fitzroy Crossing's repeated snow values were an extraction error. They are
  now zero in the accepted file.
- ERA5-Land exports for the 524-site asset are complete. The non-GHSL human-impact exports are complete. GHSL is being rerun in smaller Earth Engine jobs after the full 524-site request exceeded memory.

## 2026-07-20: Site Reference Table revisions

- Compared the July 20 living-table download with the July 16 workflow copy.
- Four Cameroon watershed files had been read with the wrong map projection,
  shifting them about 289-310 km east. The corrected copies are in the right
  location and use EPSG:4326:

| Site | Use this shapefile name | Source |
|---|---|---|
| Mbalmayo | `nyong_mbalmayo` | GLORICH catchment derived from HydroSHEDS 15s Africa; source ID 410002 |
| Olama | `nyong_olama` | GLORICH catchment derived from HydroSHEDS 15s Africa; source ID 410004 |
| Pont So'o | `soo_pontsoo` | GLORICH catchment derived from HydroSHEDS 15s Africa; source ID 410001 |
| Messam | `awout_messam` | GLORICH catchment derived from HydroSHEDS 15s Africa; source ID 410003 |

- The `nyong_ayos` file has the same projection problem, but Ayos is not in
  the accepted spatial dataset.
- Corrected coordinates in 181 existing rows:
  - All 168 PIE rows. Most had latitude and longitude reversed; the Aberjona
    row had a missing negative sign on longitude.
  - LUQ RES4, where latitude and longitude had been reversed.
  - Eight MCM rows with reversed latitude and longitude: Huey Creek at F2,
    Lost Seal Stream at F3, Aiken Creek at F5, House Stream at H2, Lyons Creek
    at B4, Santa Fe Stream at B2, Von Guerard stream at upper site, and Green
    Creek at mouth. MCM remains excluded from the accepted spatial dataset.
  - Three USGS rows updated to the documented station coordinates: Yukon
    River, Hudson River, and Mississippi River at Thebes.
  - Western Australia Fitzroy River at Fitzroy Crossing, changed from
    -18.67605, 125.4897692 to the official gauge coordinate -18.20972,
    125.5783.
- The first draft coordinates added for 12 other Western Australia gauges were
  placeholders and must be replaced with the official Bureau of Meteorology
  station coordinates below:

| Gauge | Latitude | Longitude |
|---|---:|---:|
| Kent River — Styx Junction (604053) | -34.8888450 | 117.0872223 |
| Frankland River — Mount Frankland (605012) | -34.9063889 | 116.7883334 |
| Donnelly River — Strickland (608151) | -34.3272222 | 115.7845907 |
| Blackwood River — Darradup (609025) | -34.0714774 | 115.6190781 |
| Ferguson River — Dowdells Rd Bridge (611026) | -33.3936451 | 115.7928118 |
| Thomson Brook — Woodperry Homestead (611111) | -33.6283333 | 115.9475892 |
| Collie River — South Branch (612034) | -33.3870140 | 116.1636807 |
| Collie River — Central Collie (612035) | -33.3666666 | 116.1544444 |
| Murray River — Baden Powell (614006) | -32.7722222 | 116.0843055 |
| Yarragil Brook — Yarragil Formation (614044) | -32.8111111 | 116.1555556 |
| Gingin Brook — Gingin (617058) | -31.3448611 | 115.9173612 |
| Gascoyne River — Nine Mile Bridge (704139) | -24.8274999 | 113.7691197 |

- Five other coordinate corrections remain in the newest table:

| Site | Latitude | Longitude | Source note |
|---|---:|---:|---|
| Sweden — Råne älv Niemisel | 66.0213697 | 21.9681887 | Converted from the published RT90 station coordinate |
| Sweden — Råån Helsingborg | 55.9995723 | 12.7795047 | Converted from the published SWEREF 99 TM station coordinate |
| Yzeron — V3015810 | 45.7537687 | 4.6801922 | INRAE BDOH Lambert-93 station coordinate converted to WGS84 |
| Yzeron — V301502401 | 45.7532136 | 4.7210640 | INRAE BDOH Lambert-93 station coordinate converted to WGS84 |
| Yzeron — V301502402 | 45.7563394 | 4.7472065 | INRAE BDOH Lambert-93 station coordinate converted to WGS84 |

- The two corrected Swedish points fall inside their current watershed
  polygons, so the coordinate fixes do not require new AppEEARS data. Change
  Råne älv Niemisel's drainage area to 3,781 km2. Råån Helsingborg's area
  remains under review because published values differ; do not treat the
  current 137.4543 km2 value as confirmed.
- The three Yzeron sites do not meet the current WRTDS-or-five-years rule, so
  their coordinate fixes do not add them to the AppEEARS list.
- Eleven drainage-area values had material corrections:

| Site | Previous km2 | Corrected km2 |
|---|---:|---:|
| KNZ — Kings | 10.6000 | 11.4996 |
| PIE — Aberjona | 62.0000 | 63.4547 |
| USGS — Piceance Creek at White River | 1,310.5340 | 1,688.6720 |
| USGS — Piceance Creek Ryan Gulch | 1,688.6720 | 1,310.5340 |
| USGS — Eagle River Gypsum | 481.7378 | 2,447.5388 |
| USGS — Gore Creek Upper Station | 264.1788 | 37.5548 |
| USGS — Gore Creek at Mouth | 37.5548 | 264.1788 |
| USGS — Eagle River near Minturn | 181.8172 | 481.7378 |
| USGS — Eagle River at Red Cliff | 2,447.5390 | 181.8172 |
| USGS — Colorado River near Utah State Line | 638,950.1000 | 46,228.7000 |
| USGS — Colorado River at NIB | 46,228.7000 | 638,950.1000 |

- Filled six previously blank drainage-area cells: LUQ RES4, 22.3257 km2;
  both PIE Ipswich-at-Ipswich rows, 323.7485 km2; PIE Parker and Parker River
  at Byfield, 55.1668 km2; and Fitzroy Crossing, 45,627.0015 km2.
- Standardized numerical precision for 65 other existing drainage-area values.
  These were formatting or added-decimal updates, not material watershed-area
  changes.
- One regression remains in the July 20 table download: HYBAM Serrinha's
  drainage area was cleared. Restore 286,851.9 km2, sourced from the accepted
  HydroBASINS watershed at outlet 6120218550.

### Moving-water check

- The project is limited to moving water. Exclude `Nsimi_spring` and
  Catalina Jemez `MG_S_SEEP` from new spatial work. PIE `Boxford_pond` also
  falls outside this rule and does not meet the chemistry requirement.
- Keep river or stream sites whose names mention a lake only because the gauge
  is at an inlet, outlet, or weir. They still need a real watershed before use.
- `Nsimi_outlet` is a stream outlet and remains eligible. Enter 0.60 km2 as
  its drainage area, based on the [M-TROPICS Nsimi
  record](https://hplus.ore.fr/en/nsimi/), but leave its shapefile fields blank.
  The downloadable DEIMS boundary covers the broader monitoring area, not the
  0.60 km2 outlet watershed, so it cannot be used for AppEEARS.

### Canada and Murray-Darling HydroSHEDS names

Replace the old numbered labels with names that identify both the network and
the river. This is a naming change only; the existing data do not need to be
rerun. Also fill `Shapefile_Source` with `HydroSHEDS HydroBASINS v1c upstream
watershed` and `Shapefile_CRS_EPSG` with `4326` where those cells are blank.

| Site | Old name | New `Shapefile_Name` |
|---|---|---|
| Canada — Alsek River above Bates River | `Canada1` | `canada_hydrosheds_alsek_river_above_bates_river_in_kluane_national_park` |
| Canada — Beaver River above Highway 1 | `Canada2` | `canada_hydrosheds_beaver_river_above_highway_1_in_glacier_national_park` |
| Canada — Kicking Horse River at Field | `Canada3` | `canada_hydrosheds_kicking_horse_river_at_field_in_yoho_national_park` |
| Canada — Kootenay River above Highway 93 | `Canada4` | `canada_hydrosheds_kootenay_river_above_highway_93_in_kootenay_national_park` |
| Canada — Liard River at Upper Crossing | `Canada5` | `canada_hydrosheds_liard_river_at_upper_crossing` |
| Canada — Skeena River at Usk | `Canada6` | `canada_hydrosheds_skeena_river_at_usk` |
| Murray-Darling — Barr Creek | `MD7` | `md_hydrosheds_barr_creek` |
| Murray-Darling — Broken Creek | `MD8` | `md_hydrosheds_broken_creek` |
| Murray-Darling — Gunbower Creek | `MD9` | `md_hydrosheds_gunbower_creek` |
| Murray-Darling — Heywoods | `MD10` | `md_hydrosheds_heywoods` |
| Murray-Darling — Kiewa River at Bandiana | `MD11` | `md_hydrosheds_kiewa_river_at_bandiana` |
| Murray-Darling — Lock 5 | `MD12` | `md_hydrosheds_lock_5` |
| Murray-Darling — Mitta Mitta at Colemans | `MD13` | `md_hydrosheds_mitta_mitta_at_colemans` |
| Murray-Darling — Mitta Mitta at Talandoon | `MD14` | `md_hydrosheds_mitta_mitta_at_talandoon` |
| Murray-Darling — Murrumbidgee River at Balranald | `MD15` | `md_hydrosheds_murrumbidgee_river_at_balranald` |
| Murray-Darling — Rufus River Junction | `MD16` | `md_hydrosheds_rufus_river_junction` |
| Murray-Darling — Swan Hill | `MD17` | `md_hydrosheds_swan_hill` |
| Murray-Darling — Torrumbarry | `MD18` | `md_hydrosheds_torrumbarry` |

Do not rename the four Murray-Darling rows that use official Australian gauge
catchments instead of HydroSHEDS: Merbein, Euston Weir, Barham, and Jingellic.

## 2026-07-20: final AppEEARS follow-up preparation

- The full 980-row table was checked before preparing the last request. Sites
  without a trustworthy watershed were not submitted.
- Twelve sites are ready: four corrected existing Cameroon sites, six new
  Finnish sites, and two new Western Australia sites.

| Site | Shapefile name | Source | Source ID | Polygon area km2 |
|---|---|---|---:|---:|
| Cameroon — Mbalmayo | `nyong_mbalmayo` | GLORICH catchment derived from HydroSHEDS 15s Africa | 410002 | 14,349.18 |
| Cameroon — Olama | `nyong_olama` | GLORICH catchment derived from HydroSHEDS 15s Africa | 410004 | 19,161.11 |
| Cameroon — Pont So'o | `soo_pontsoo` | GLORICH catchment derived from HydroSHEDS 15s Africa | 410001 | 1,265.36 |
| Cameroon — Messam | `awout_messam` | GLORICH catchment derived from HydroSHEDS 15s Africa | 410003 | 194.18 |
| Finnish Environmental Institute — Kisko 14 Vanhak va6111 | `kiskonjoen_pernionjoen_vesistoalue` | Syke national catchment division | 124 | 1,045.65 |
| Finnish Environmental Institute — Uske 16 Salon yp va6101 | `uskelanjoen_vesistoalue` | Syke national catchment division | 125 | 566.02 |
| Finnish Environmental Institute — Pajo 44 Isosilta va6301 | `paimionjoen_vesistoalue` | Syke national catchment division | 127 | 1,094.43 |
| Finnish Environmental Institute — Aura 54 ohikulku va6401 | `aurajoen_vesistoalue` | Syke national catchment division | 128 | 869.03 |
| Finnish Environmental Institute — Eura 42 Pori-Rma va6900 | `eurajoen_vesistoalue` | Syke national catchment division | 134 | 1,338.83 |
| Finnish Environmental Institute — Kojo 35 Pori-Tre | `kokemaenjoen_vesistoalue` | Syke national catchment division | 135 | 27,191.42 |
| Western Australia — Thomson Brook — Woodperry Homestead | `thomson_brook_woodperry_homestead_bom_geofabric` | Bureau of Meteorology Geofabric V3.3 | 611111 | 102.05 |
| Western Australia — Yarragil Brook — Yarragil Formation | `yarragil_brook_yarragil_formation_bom_geofabric` | Bureau of Meteorology Geofabric V3.3 | 614044 | 72.98 |

- All twelve polygons are valid, contain the relevant gauge or outlet, and are
  not copies of a current watershed. Thomson Brook differs from the official
  gauge area by -3.79%; Yarragil Brook differs by +2.24%.
- The other ten Western Australia sites remain on hold because their mapped
  areas did not agree closely enough with the official gauge areas, or the
  Geofabric river link was missing.
- No final follow-up request had been submitted at the time of this update.

## 2026-07-20: Box cleanup

- Copied the corrected July 20 extract, its check and change logs, coverage tables, and AppEEARS QA plots to `spatial-data-files/appeears-nasa/`.
- Removed 3,193 unreferenced files from `artisanal-shapefiles-2/`, retaining all sidecars for the 27 shapefiles referenced directly by the accepted watershed package.
- Removed rejected July 15 candidate folders, the MCM channel-polygon archive, 17 unreferenced reprojection folders, the superseded 120 MB `silica-watersheds` package, and the replaced July 19 wide CSV.
- Retained the current combined watershed source, all accepted recovered-site bundles, and the source README for the five July 17 recoveries.
- The watershed-source area decreased from 416 MB to 129 MB. Post-cleanup validation found 524 valid, nonempty geometries, 524 unique site IDs, all 62 source shapefiles present, and all 248 required shapefile sidecars present.
- No Google Drive upload was performed.
