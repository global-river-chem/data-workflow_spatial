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

## Current AppEEARS status

- The targeted ET and snow updates are complete, downloaded, combined, and
  checked. They filled missing values for 22 sites.
- Four new LMP sites and Fitzroy Crossing were added after reliable watershed
  files were found and their AppEEARS extractions were completed.
- Coverage for 2002-2022 is complete for 521 of the 524 sites. The remaining
  cycle-0 green-up gaps stayed missing after reruns because MODIS did not
  return usable data for those site-years. Cycle 1 is optional.
- The final 12-site request set was submitted on July 20: four corrected
  Cameroon watersheds, six Finnish watersheds, and Thomson Brook and Yarragil
  Brook in Western Australia. AppEEARS accepted all 12 requests; two began
  processing immediately and ten were pending.
- Next: monitor the 12 requests, then download, combine, and check the results.

## Dataset checkpoints

| Date | File or package | Site accounting | Material change |
|---|---|---:|---|
| 2025-03-25 | `all-data_si-extract_2_20250325.csv` | 570 rows; 497 unique normalized LTER/stream names; 367 columns | Baseline used for this change log. The file is retained with the archived GRL submission inputs. |
| 2026-06-29 | `all-data_si-extract_3_20260629.csv` | 543 unique sites; 401 columns | Combined the May-June reruns and new sites. Seventy site names were not in the March file after matching both stream and discharge names. Repeated names for the same March site were combined. |
| 2026-07-14 | `all-data_si-extract_3_20260629_with_coast_distance.csv` | 543 | Added distance-to-coast values; no site rows were added. |
| 2026-07-16 | `all-data_si-extract_3_20260716.csv` | 543 | Added targeted AppEEARS results for Andrews Creek, Serrinha, KRR S65B, and DMF Brazos River; no site rows were added. |
| 2026-07-17 | `all-data_si-extract_3_20260717.csv` | 543 | Filled ET and snow gaps for 22 sites; no site rows were added. |
| 2026-07-18 | `all-data_si-extract_3_20260718_unfiltered_intermediate.csv` | 548 | Added five sites after finding reliable watershed files and completing their AppEEARS extractions. |
| 2026-07-19 | `all-data_si-extract_3_20260719.csv` | 524 | Removed 24 sites that did not have a reliable watershed. |
| 2026-07-20 | `appeears_spatial-extract_524sites_20260720.csv` | 524 | Ran the usual snow and permafrost checks for the five recently added sites. Fitzroy Crossing snow was set to zero, and missing permafrost values were set to zero for Fitzroy Crossing and the four new LMP sites. |

## May 8-24, 2026: reviewed watersheds and added sites

- Reviewed the sites that might be able to use HydroSHEDS and kept only the ones with a watershed we could defend. The May 14 review approved full AppEEARS coverage for Cameroon Mbalmayo, Messam, Olama, and Pont So'o, along with the missing recent years for six Canadian sites and nine Murray-Darling sites.
- The May 23 land-cover extraction included 48 site names. Forty-seven were additions to the March file; Yampa River Below Craig was already present and was included because it needed an update.
- The sites added in May came from the following watershed sources:
  - Amazon: 11 GLORICH watershed files for Amazon River at Itapeua, Manacapuru, Santo Antonio do Ica, and Vargem Grande, plus Rio Ica, Japura, Jurua, Jutai, Madeira, Negro, and Purus.
  - ColoradoAlpine: Loch, using the Loch Vale Watershed Study file `lvws_basin`.
  - Cameroon: Mbalmayo, Messam, Olama, and Pont So'o, using the supplied Nyong, Awout, and Soo watershed files. These files were later corrected because their original map projection had been read incorrectly.
  - EastRiverSFA: 12 project-supplied watershed files: `ce_cmt0`, `coal_11`, `er_brd1`, `er_cpr1`, `er_eaq1`, `er_ebc1`, `er_phf0`, `er_rck1`, `er_rus1`, `lo_loc1`, `sg_suf1`, and `tr_tcg1`.
  - Guadeloupe: six BD CARTHAGE watersheds for Capesterre, La Digue; Maison de la Forêt; Petit Bras-David; Ravine Quiock; Vieux-Habitants, Barthole; and Vieux-Habitants, Savanne-Beauséjour.
  - Murray-Darling: Barham and Jingellic, using the official Australian files `AUS_409005` and `AUS_401201`.
  - NWT: `como`, using the existing Como Creek watershed. These are two names for the same site, not two different watersheds.
  - Seine: seven project-supplied watersheds for Amfreville-sous-les-Monts, Bennecourt, Carrieres-sous-Poissy, Ivry-sur-Seine, Paris-12e--Arrondissement, Poses 3, and Triel-sur-Seine.
  - USGS: Arkansas River at Murray Dam, Columbia River at Port Westward, and North Sylamore. North Sylamore was later replaced with a watershed downloaded from USGS NLDI specifically for that gauge.
- EastRiverSFA `coal_11` is also the same site and watershed as the older Coal Creek row. Both names are still present in the 524-site file, but they should not be treated as two independent watersheds.

## By June 29, 2026: other sites added after March

The June 29 file contained 23 more site names that were not part of the May 23 land-cover extraction:

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

Several were added to the table before we had found a reliable watershed for them. ARC, the Nsimi sites, HYBAM Obidos, LUQ QP, the five MCM sites, and KRR S65B were later removed from the final spatial file. The sites for which we did find reliable watersheds are listed below.

## July 15, 2026: new watershed files found and documented

| Site | Living-table `Shapefile_Name` | Where the watershed came from | HydroSHEDS? | Used in final file? |
|---|---|---|---|---|
| ColoradoAlpine — Andrews Creek | `andrews_nldi` | USGS NLDI watershed for the gauge | No | Yes |
| ColoradoAlpine — Loch | `lvws_basin` | Loch Vale Watershed Study spatial data | No | Yes |
| HYBAM — Labrea | `labrea_hydrosheds` | Combined upstream HydroBASINS watershed; outlet `6120400480` | Yes | Yes |
| HYBAM — Serrinha | `serrinha_hydrosheds` | Combined upstream HydroBASINS watershed; outlet `6120218550` | Yes | Yes |
| HYBAM — Tabatinga | `tabatinga_hydrosheds` | Combined upstream HydroBASINS watershed; outlet `6120313630` | Yes | Yes |
| LMP — NOR27 | `nor27_nldi` | USGS NLDI watershed for the gauge | No | Yes |
| USGS — DMF Brazos River | `dmf_brazos_river_gagesii` | USGS GAGES-II watershed for gauge 08079600 | No | Yes |
| USGS — North Sylamore | `north_sylamore_nldi` | USGS NLDI watershed for the gauge | No | Yes |

AppEEARS was rerun with the corrected watersheds for Andrews Creek, Serrinha, and DMF Brazos River. KRR S65B was also run, but it was later removed because `s_65bc` covers the combined S-65BC management area rather than a watershed unique to S65B.

## July 16-17, 2026: fixed watersheds and filled missing AppEEARS data

- Fazenda Vista Alegre had been assigned the wrong `rio_madeira` watershed. It was replaced with `fazenda_vista_alegre_hydrosheds`, the combined upstream HydroBASINS watershed at outlet `6120330250`. Its mapped area is 1,314,827.1 km², compared with 1,317,760 km² in the reference table, a difference of -0.223%.
- The supplied KRR file `s_65bc` covers the combined S-65BC management area. The final spatial file keeps it once under S65C and removes S65B so the same area is not counted twice. It should not be described as a watershed unique to S65C.
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

## July 17-19, 2026: five more sites added

| Site | Living-table `Shapefile_Name` | Source and check | HydroSHEDS? |
|---|---|---|---|
| LMP — LTR20 | `ltr20_nldi` | USGS NLDI COMID 5848028; 49.279 km² versus 51.7 km² reference | No |
| LMP — NBR12 | `nbr12_nldi` | USGS NLDI COMID 5848142; 44.568 km² versus 41.5 km² reference | No |
| LMP — PWT03 | `pwt03_nldi` | USGS NLDI COMID 5848050; 2.968 km² versus 2.6 km² reference | No |
| LMP — RMB04 | `rmb04_nldi` | USGS NLDI COMID 5848152; 4.913 km² versus 4.9 km² reference | No |
| WesternAustralia — Fitzroy River — Fitzroy Crossing | `fitzroy_river_fitzroy_crossing_bom_geofabric` | Bureau of Meteorology Geofabric V3.3 station catchment for gauge 802055; 45,627.002 km² | No |

- Each watershed contains its gauge or outlet, passed the geometry checks, and is different from the other watersheds in the final file.
- Fitzroy Crossing must use the official gauge coordinate: longitude 125.5783, latitude -18.20972.
- The five watershed files and their README are stored in `silica-shapefiles/recovered-20260717/`.
- Their AppEEARS results were downloaded, extracted, combined, and added to the July 18 working file.

## July 19, 2026: removed sites without a reliable watershed

The 548-site working file was reduced to 524 sites. The following rows were removed because they did not have a reliable watershed:

- Four ARC sites: Imnavait Upper, Imnavait WT 07 Weir, Toolik Inlet, and TW Weir.
- Congo Basin Nsimi Outlet and Nsimi Spring.
- HYBAM Obidos; the GRO Obidos row is the one kept in the final file.
- KRR S65B; S65C is the one row kept for the combined `s_65bc` management area.
- LUQ QP; its NLDI candidate was 3.32 km² versus the 0.31 km² reference area and was rejected.
- All 15 MCM rows. Ten had stream-channel shapes rather than watersheds, and five had no usable watershed. No MCM rows remain in the final spatial file.

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
- Ravine Quiock's BD CARTHAGE watershed is 9.76 km² while the reference table says 0.78 km². A square-mile conversion does not explain the difference: 0.78 mi² is about 2.02 km². The reference drainage area still needs to be checked.
- Fitzroy Crossing's repeated snow values were an extraction error. They are
  now zero in the final file.
- ERA5-Land exports for all 524 watersheds are complete. The human-impact exports other than GHSL are also complete. GHSL is being rerun in smaller Earth Engine jobs because the single 524-site job was too large.

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
- Eleven drainage-area values were actually wrong and were corrected:

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
- Updated the number of decimal places shown for 65 other drainage-area
  values. Their watershed areas did not change.
- HYBAM Serrinha's drainage area was accidentally cleared in the July 20
  table download. Restore 286,851.9 km2, based on the HydroBASINS watershed
  at outlet 6120218550.

### Moving-water check

- The project is limited to moving water. Exclude `Nsimi_spring` and
  Catalina Jemez `MG_S_SEEP` from new spatial work. PIE `Boxford_pond` also
  falls outside this rule and does not meet the chemistry requirement.
- Keep river or stream sites whose names mention a lake only because the gauge
  is at an inlet, outlet, or weir. They still need a real watershed before use.
- `Nsimi_outlet` is a stream outlet and still meets the project rules. Enter 0.60 km2 as
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

## July 20, 2026: final AppEEARS sites

- All 980 rows were checked before preparing the last request. Sites
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

- All 12 watersheds passed the geometry checks, contain the relevant gauge or outlet, and are
  different from the watersheds already in the final file. Thomson Brook differs from the official
  gauge area by -3.79%; Yarragil Brook differs by +2.24%.
- The other ten Western Australia sites remain on hold because their mapped
  areas did not agree closely enough with the official gauge areas, or the
  Geofabric river link was missing.
- All 12 requests were submitted and accepted by AppEEARS on July 20. The
  submission record contains 12 unique task IDs with no remaining duplicate
  tasks.

## 2026-07-20: Box cleanup

- Copied the corrected July 20 extract, its check and change logs, coverage tables, and AppEEARS QA plots to `spatial-data-files/appeears-nasa/`.
- Removed 3,193 unused files from `artisanal-shapefiles-2/`. Kept the 27 watershed shapefiles used by the final file, along with their required `.dbf`, `.shx`, and `.prj` files.
- Removed rejected July 15 candidate folders, the MCM channel-polygon archive, 17 unreferenced reprojection folders, the superseded 120 MB `silica-watersheds` package, and the replaced July 19 wide CSV.
- Retained the current combined watershed source, all accepted recovered-site bundles, and the source README for the five July 17 recoveries.
- The watershed folder decreased from 416 MB to 129 MB. After cleanup, the final watershed file still contained 524 valid watersheds and 524 unique site IDs. All 62 source shapefiles and their 248 required companion files were present.
- No Google Drive upload was performed.
