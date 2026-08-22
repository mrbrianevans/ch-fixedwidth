# Companies House Product 198 - Company Appointments Update

> **Status: implemented.** Library, CLI, and WASM accept update files (`DDDDUPDT`, product 198) and emit company + person CSVs. **Person columns are not the snapshot (195/216) schema**: update rows carry old/new identifiers and change/update dates. Company columns match the snapshot company record (same on-disk layout).

**File Type**: Update (`DDDDUPDT` header)

**General**  
- Contains Header + multiple Company + Update Person records + Trailer  
- Records are sequential.  
- Dates: `CCYYMMDD` or spaces.  
- Delimiters: `<` (chevron).  
- Person numbers: 12-digit numeric.  
- Company numbers: 8 chars (spaces for nominee corrections).

## 1. Header Record (Fixed, 20 bytes)
| Start | End | Length | Field | Type | Notes |
|-------|-----|--------|-------|------|-------|
| 1     | 8   | 8      | Header Identifier | String | `DDDDUPDT` |
| 9     | 12  | 4      | Run Number | Numeric | |
| 13    | 20  | 8      | Production Date | Date | `CCYYMMDD` |

## 2. Trailer Record (Fixed, 16 bytes)
| Start | End | Length | Field | Type | Notes |
|-------|-----|--------|-------|------|-------|
| 1     | 8   | 8      | Trailer Identifier | String | `99999999` |
| 9     | 16  | 8      | Record Count | Numeric | Excludes header/trailer |

## 3. Company Record
**Variable length**, max 201 bytes.

| Start | End | Length | Field | Type | Notes |
|-------|-----|--------|-------|------|-------|
| 1     | 8   | 8      | Company Number | String | |
| 9     | 9   | 1      | Record Type | Char | `1` |
| 10    | 10  | 1      | Company Status | Char | `C/D/L/R`/space |
| 11    | 32  | 22     | Filler | - | |
| 33    | 36  | 4      | Number of Officers | Numeric | |
| 37    | 40  | 4      | Company Name Length | Numeric | Includes `<` |
| 41    | ... | var    | Company Name | String | `<` delimited |

## 4. Update Person Record
**Variable length**, max 1048 bytes.

| Start | End | Length | Field | Type | Notes |
|-------|-----|--------|-------|------|-------|
| 1     | 8   | 8      | Company Number | String | Spaces for nominees |
| 9     | 9   | 1      | Record Type | Char | `2` |
| 10    | 10  | 1      | App Date Origin | Char | |
| 11    | 11  | 1      | Res Date Origin | Char | |
| 12    | 12  | 1      | Correction Indicator | Char | `Y`/space |
| 13    | 13  | 1      | Corporate Indicator | Char | `Y`/space |
| 14    | 15  | 2      | Filler | - | |
| 16    | 17  | 2      | Old Appointment Type | Numeric | |
| 18    | 19  | 2      | New Appointment Type | Numeric | 00-07,11-22,99 |
| 20    | 31  | 12     | Old Person Number | Numeric | |
| 32    | 43  | 12     | New Person Number | Numeric | |
| 44    | 51  | 8      | Partial DOB | String | |
| 52    | 59  | 8      | Full DOB | Date | |
| 60    | 67  | 8      | Old Person Postcode | String | |
| 68    | 75  | 8      | New Person Postcode | String | |
| 76    | 83  | 8      | Appointment Date | Date | |
| 84    | 91  | 8      | Resignation Date | Date | |
| 92    | 99  | 8      | Change Date | Date | |
| 100   | 107 | 8      | Update Date | Date | |
| 108   | 111 | 4      | Variable Data Length | Numeric | |
| 112   | ... | var    | Variable Data | String | 27 `<` fields (14 named + trailing fillers) |

**Published person CSV** (product-specific; do not reuse snapshot headers): Company Number, App Date Origin, Res Date Origin, Correction Indicator, Corporate Indicator, Old/New Appointment Type, Old/New Person Number, Partial/Full DOB, Old/New Person Postcode, Appointment Date, Resignation Date, Change Date, Update Date, then the 14 named chevrons (New Title, New Forenames, New Surname, New Honours, Care Of, PO Box, New Address Line 1–2, New Post Town, New County, New Country, Occupation, New Nationality, New Residential Country).

**Trailing chevron fillers (fields 15–27):** omitted from the published schema after a bulk proof on `Prod198_4271` (12 239 person rows, 0 non-empty fillers; max split width 28 from a trailing delimiter). A non-empty filler **fails the parse** (`ExtraChevronData` / `CH_ERR_FIELD_OVERFLOW`) so this omission cannot silently drop data.

**Company filler bytes 11–32:** spec-named unused filler; not exported (same published company schema as the snapshot).

**Parser Notes**: Match on Company + Old Type + Old Person Number. Apply logic for new appointments, resignations, changes, corrections, merges, etc. (per source doc sections 4.2-4.9). Nominee corrections have Company=spaces and Person Numbers starting with `9`.


## More info

General: https://chguide.co.uk/bulk-data/officers/update-file/

Person update record format: https://chguide.co.uk/bulk-data/officers/update-file/personUpdateRecord

## Sample data
```
DDDDUPDT172420161018
019742101                       00070030WEST MIDLANDS ARTS TRUST(THE)<
0197421021     0101216582660001216582660001196002                  B1 1BB  20160629                201610180138COUNCILLOR<DESMOND<HUGHES<<<<COUNCIL HOUSE VICTORIA SQUARE<<BIRMINGHAM<<UNITED KINGDOM<SUPPORT WORKER<BRITISH<UNITED KINGDOM<<<<<<<<<<<<<<
01974210211    0103200204450001200204450001197804                  B1 1BB  2015062420160713        201610180143COUNCILLOR<PENNY<HOLBROOK<<<<COUNCIL VICTORIA SQUARE<<BIRMINGHAM<WEST MIDLANDS<ENGLAND<LOCAL AUTHORITY COUNCILLOR<BRITISH<ENGLAND<<<<<<<<<<<<<<
021978411                       00030032DUNSTAN BREARLEY TRAVEL LIMITED<
0219784121  Y  0101166895510001130695310001                        M60 4ES 20111231        20161018201610180112<<CWS (NO.1) LIMITED<<<<NEW CENTURY HOUSE CORPORATION STREET<<MANCHESTER<<UNITED KINGDOM<<BRITISH<<<<<<<<<<<<<<<
022015521                       00050025BONDLAW NOMINEES LIMITED<
0220155221  Y  0000059771390005059771390005                        SE1 2AU 19921018                201610180112<<BONDLAW SECRETARIES LIMITED<<<<4 MORE LONDON RIVERSIDE<<LONDON<<ENGLAND<FORMATION AGENT<BRITISH<<<<<<<<<<<<<<<
026471901                       00090021B G C (1991) LIMITED<
0264719021     0101003168570001003168570001194904                  HP9 2UR 20161015                201610180118MR<PATRICK JOSEPH<BYRNE<<<<BEACONSFIELD GOLF CLUB<SEER GREEN<BEACONSFIELD<BUCKS<<RETIRED<BRITISH<ENGLAND<<<<<<<<<<<<<<
0264719021     0101202599790001202599790001196003                  HP9 2UR 20161015                201610180117MR<TIM CLIVE<WHITTAKER<<<<BEACONSFIELD GOLF CLUB<SEER GREEN<BEACONSFIELD<BUCKS<<RETIRED<BRITISH<ENGLAND<<<<<<<<<<<<<<
0264719021     0101216575880001216575880001195810                  HP9 2UR 20161015                201610180117MRS<AMANDA<BARTHOLOMEW<<<<BEACONSFIELD GOLF CLUB<SEER GREEN<BEACONSFIELD<BUCKS<<RETIRED<BRITISH<ENGLAND<<<<<<<<<<<<<<
02647190211    0103000844970001000844970001195110                  HP9 2UR 2010101720161015        201610180129MR<JOHN EDWARD<BAILEY<<<<BEACONSFIELD GOLF CLUB<SEER GREEN<BEACONSFIELD<BUCKS<<CHARTERED ACCOUNTANT<BRITISH<ENGLAND<<<<<<<<<<<<<<
02647190211    0103069920630001069920630001194605                  HP9 1XY 2002113020161015        201610180143<DAVID<LEWIS<<<<PENNYFIELD 9 PITCH POND CLOSE<KNOTTY GREEN<BEACONSFIELD<BUCKINGHAMSHIRE<<MANAGING DIRECTOR<BRITISH<UNITED KINGDOM<<<<<<<<<<<<<<
9999999900000013
```

(Trailer count is company + person data rows excluding header/trailer: 4 companies + 9 persons = 13.)