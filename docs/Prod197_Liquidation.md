# Companies House Product 197 – Liquidation Daily Updates

> **Status: implemented.** Library, CLI, and WASM accept `LIQNFORM` files and emit three named CSVs: forms (`CH_OUTPUT_FORMS`), practitioners (`CH_OUTPUT_PRACTITIONERS`), and free text (`CH_OUTPUT_FREE_TEXT`). Trailer count is validated against the total number of data records (every non-header/non-trailer line).

**File Format Specification (V4.6d, issued 25 April 2019)**  
Source: Companies House Liquidation Database Bulk Data Products

**File Type**: Liquidation daily update (`LIQNFORM` header)

## General

- The extract is a **variable-length, multi-record-type** file (unlike fixed-width officers products).
- Each data record starts with a **two-character identifier** that determines the record type and length.
- Structure:
  - 1 header record
  - Zero or more **form groups** (each group starts with an `FM` record)
  - 1 trailer record
- Different record types are grouped according to the **form** they relate to.
- Dates on data records are typically `DDMMCCYY` (day-first), **not** the `CCYYMMDD` used in the header production date and in officers products.
- Practitioner (`NP`) and registered office (`RE`) fields use **chevron** (`<`) delimiters for name/address elements (same character family as officers products; the CH spec describes these as left-pointing chevrons).

### Syntax conventions (form layouts)

Used in official form layouts to indicate grouping and relationship between record types:

| Notation | Meaning |
|----------|---------|
| `XX` | Record type XX occurs once only |
| `XX...` | Record type XX occurs at least once |
| `[XX]` | Record type XX optional |
| `[XX]...` | Optional record XX may occur once or more than once |

A complete parser must follow the **exact ordered sequence** of record identifiers for each form number (sections 4–7 of the source specification). Those per-form sequences are summarised by form list below; the full ordered layouts are not reproduced here.

---

## 1. Header Record

Fixed length: **20** characters.

| Start | End | Length | Format | Field | Notes |
|-------|-----|--------|--------|-------|-------|
| 1 | 8 | 8 | X(8) | Header identifier | `LIQNFORM` |
| 9 | 12 | 4 | 9(4) | Daily run number | |
| 13 | 20 | 8 | 9(8) | Production date | `CCYYMMDD` |

Example: `LIQNFORM000120090630`  
(liquidation daily update numbered one, run on 30 June 2009)

Real sample: `LIQNFORM427620260731` (run 4276, 31 July 2026).

---

## 2. Trailer Record

Fixed length: **16** characters.

| Start | End | Length | Format | Field | Notes |
|-------|-----|--------|--------|-------|-------|
| 1 | 8 | 8 | X(8) | Trailer identifier | `99999999` |
| 9 | 16 | 8 | 9(8) | Number of records | **Excludes** header and trailer |

Example: `9999999900024450` → 24,450 data records.

Real sample: `9999999900002215` → 2,215 data rows (line count of the sample file is 2,217 including header + trailer).

---

## 3. Record types (Appendix 1)

All data records begin with a 2-character identifier.

### 3.1 AD – Appointment Date

**10** bytes: identifier + date `DDMMCCYY`.

Example: `AD03051994` (3 May 1994)

### 3.2 CO – Court Reference Number

**15** bytes: identifier + 8-character reference (left-justified, often zero-padded) + `/` + year.

Example (spec): `CO00123456/1994`

Real samples may use alphanumeric court tokens, e.g. `CO0HAM L15/2026`.

### 3.3 DO – Date of Order

**10** bytes: identifier + date `DDMMCCYY`.

Example: `DO03051994`

### 3.4 DP – Date of Petition

**10** bytes: identifier + date `DDMMCCYY`.

Example: `DP03051987`

### 3.5 FM – Form Number/Type

**12** bytes: identifier + 10-character form number, left-justified with trailing spaces.

Example (spec): `FM4.43`

Modern daily files often use current form codes (padded to 10 characters), e.g. `FM600       `, `FMLIQ13     `, `FMAM01      `, `FMRESS      `.

Each form group **starts** with an `FM` record.

### 3.6 FT – Free Text

**42** bytes: identifier + up to 40 characters of supporting text, left-justified with trailing spaces.

Examples:

- `FTREGISTERED PURSUANT TO AN ORDER OF COURT`
- `FT DATED 29TH MAY 1982` + trailing spaces
- Nature of business on form 600: `FTPURVEYOR OF HIGH CLASS PROVISIONS`
- Form registered in error (spec):  
  `FT ************************ FORM REGISTERED IN ERROR ********`
- Real sample (shorter wording also appears):  
  `FT *** FORM REGISTERED IN ERROR ***`

### 3.7 MD – Final Meeting Date

**10** bytes: identifier + date `DDMMCCYY`.

Example: `MD03051987`

### 3.8 NA – Name of company

**102** bytes: identifier + company name (left-justified, trailing spaces). Up to 100 characters of name.

Example: `NAPOWER PACKAGES LTD` + trailing spaces

### 3.9 NP – Name of Practitioner

**102** bytes: identifier + up to 100 characters of text, left-justified with trailing spaces.

`NP` records contain **five** chevron delimiters that separate name and address elements.

Example (spec style):  
`NPJ WASHINGTON<NEWTON HOUSE<CHEADLE<RD<LEEK<STAFFS<` + trailing spaces

Rules from the specification:

- Each record holds details of **only one** practitioner.
- Address overflow continues in the next `NP` record if needed.
- Second and subsequent practitioners appear in **separate** records after the five chevrons have been encountered.

Real multi-practitioner example:

```
NPI MACNEIL<WEST GEORGE STREET<GLASGOW<G2 2LB<<
NPB W MILNE<WEST GEORGE STREET<GLASGOW<G2 2LB<<
```

### 3.10 RD – Resolution Date

**10** bytes: identifier + date `DDMMCCYY`.

Example: `RD03051987`

### 3.11 RE – Registered Office Address

**102** bytes: identifier + up to 100 characters, left-justified with trailing spaces.

Five chevrons delimit address elements; overflow continues in subsequent `RE` records if needed.

Example:  
`RECOMPANIES HOUSE<CROWN WAY<MAINDY<CARDIFF<<`

### 3.12 RN – Registered Company Number

**10** bytes: identifier + registered company number.

Company numbers are either:

- 8 digits, or
- a two-character prefix + 6 digits

**England/Wales prefixes:** AC, FC, GE, IC, IP, LP, OC, RC, ZC, FE  

**Scotland:** GS, SA, SC, SF, SI, SL, SO, SP, SR, SZ  

**Northern Ireland:** GN, NA, NC, NF, NI, NL, NO, NP, NR, NV, NZ, R0 (R followed by zero)

Examples: `RNO2654354`, `RNSC104582`, `RNFC001478`, `RNSF000540`

### 3.13 TD – Termination Date

**10** bytes: identifier + date `DDMMCCYY`.

Example: `TD03051987`

---

## 4. Additional record types (form layouts)

These identifiers appear in form sequences with the formats below (limited definition in Appendix 1 of the source):

| ID | Length (typical) | Format | Meaning |
|----|------------------|--------|---------|
| `DR` | 10 | X(8) after id → `DDMMCCYY` | Date form registered |
| `FD` | 10 | X(8) after id → `DDMMCCYY` | Form dated |
| `ID` | 12 | 9(10) after id | Transaction identifier |
| `ND` | 10 | X(8) after id → `DDMMCCYY` | New dissolution date |

In practice, form groups in recent daily files almost always end with `DR` + `ID` (and optionally `FT` before `ID`).

---

## 5. Form groups

The body of the file is a sequence of form groups. Each group:

1. Begins with an `FM` record (form number/type)
2. Continues with the ordered record types defined for that form
3. Ends when the next `FM` (or the trailer) is encountered

### 5.1 Forms listed in the V4.6d specification

**Voluntary Arrangements**  
1.1, CVA1, 1.2, CVA2, 1.4, CVA4, 1.1(SCOT), 1.2(SCOT), 1.4(SCOT), 1.1(NI), 1.2(NI), 1.4(NI), CVA1(SCOT), CVA2(SCOT), CVA4(SCOT)

**Administration Orders**  
2.6, 2.7, 2.19, 2.1(SCOT), 2.2(SCOT), 2.3(SCOT), 2.4(SCOT), 2.12(SCOT), 2.07(NI), 2.08(NI), 2.20(NI)

**In Administration**  
2.12B, AM01, 2.30B, AM20, 2.32B, AM21, 2.33B, AM25, 2.34B, AM22, 2.35B, AM23, 2.36B, AM24, 2.11B(SCOT), 2.21B(SCOT), 2.23B(SCOT), 2.24B(SCOT), 2.25B(SCOT), 2.26B(SCOT), 2.27B(SCOT), 2.12B(NI), 2.30B(NI), 2.32B(NI), 2.33B(NI), 2.34B(NI), 2.35B(NI), 2.36B(NI), AM01(SCOT), AM20(SCOT), AM21(SCOT), AM22(SCOT), AM23(SCOT), AM24(SCOT)

**Voluntary Liquidations**  
Special Resolution, Extraordinary Resolution, 600, 4.71, LIQ13, 4.72, LIQ14, 4.26(SCOT), 39C(NI), 39D(NI), 558(NI), 558A(NI), 558B(NI), 558C(NI), 4.72(NI), 4.73(NI), LIQ13(SC), LIQ14(SC)

**Compulsory Liquidations**  
F14, WU01, Court Order, 4.31, WU04, L64.07, L64.07HC, L64.01, 4.43, WU15, Staying or Rescinding Order, 4.2(SCOT), 4.9(SCOT), 4.17(SCOT), 4.27(SCOT), 4.28(SCOT), 4.23(NI), 4.32(NI)

The exact ordered list of record identifiers and occurrence rules for each form is defined in the corresponding subsections of the source document (not fully reproduced here). A production parser should validate sequences against that table, while remaining tolerant of **newer form codes** that appear in live extracts but post-date V4.6d.

### 5.2 Form codes seen in a recent live extract

Observed on a daily file (run 4276). Counts are for that file only; they illustrate modern form naming and mix, not official catalogue completeness:

| Form (`FM`) | Approx. count | Notes |
|-------------|---------------|-------|
| `600` | high | Voluntary liquidation; often has `NP...`, `AD`, `FT` (nature of business) |
| `RESE` / `RESS` | common | Resolution-related; often `RD` + `DR` + optional error `FT` |
| `LIQ13` / `LIQ13(SC)` | common | Often minimal: `RN`, `NA`, `DR`, `ID` |
| `LIQ14` / `LIQ14(SC)` | common | Similar to LIQ13 |
| `AM01`, `AM20`, `AM21`, `AM23` | present | Administration |
| `AM03(SCOT)` | rare | Scottish admin variant |
| `CO` | present | Court order / compulsory path; often `CO`, `RN`, `NA`, `NP`, `DO`, `DP` |
| `WU01(SCOT)`, `WU04`, `WU15`, `WU15(SCOT)`, `WU16(SCOT)` | present | Winding-up forms |
| `CVA4` | rare | Voluntary arrangement |
| `VL1` | rare | NI voluntary liquidation style |
| `RCOM`, `RMVL`, `647`, `212B` | rare | Other modern / legacy codes |

Record-type mix on that same file (illustrative): `FM`/`RN`/`NA`/`DR`/`ID` always align with form-group count; `NP` and `FT` are frequent; `AD`/`RD` common; `CO`/`DO`/`DP`/`FD`/`TD` less common; `RE` rare; `MD`/`ND` may be absent on a given day.

---

## 6. Implementation notes

1. **Dispatch**: first 8 bytes `LIQNFORM`.
2. **Form-group model**: each `FM` starts a group; the previous group is flushed when the next `FM` or the trailer is seen.
3. **Unknown tags**: logged as warnings (`unknown tag XX on form … company …`) and still counted toward the trailer. The run succeeds (exit 0) if the trailer matches. This is **not** a complete V4.6d per-form sequence parser.
4. **Field overflow**: single-value slots, `NP`, `FT`, and `RE` fail closed (`CH_ERR_FIELD_OVERFLOW` / `CH_ERR_RECORD_LIMIT`); values are never truncated.
5. **Chevrons**: `NP` rows split on `<` into Name + up to five address lines; `RE` is kept as a single registered-office string (chevrons preserved).
6. **Dates**: data-record dates are exported as in the file (`DDMMCCYY`); header production date remains `CCYYMMDD`.
7. **Trailer validation**: every non-header/non-trailer line counts; total must match the trailer’s 8-digit count.
8. **CLI sequential only** (form-group state cannot be split across workers like officers products).
9. **CSV outputs** (CLI filenames and `OutputKind` / `CH_OUTPUT_*` — never overloaded onto companies/persons):

| CLI file | Output kind | Content |
|----------|-------------|---------|
| `forms_data_*` | `forms` | One row per form group |
| `practitioners_data_*` | `practitioners` | One row per `NP` |
| `free_text_data_*` | `free_text` | One row per `FT` |

**forms columns:** Form Number, Company Number, Company Name, Court Reference, Appointment Date, Date of Order, Date of Petition, Resolution Date, Final Meeting Date, Termination Date, Date Form Registered, Form Dated, New Dissolution Date, Transaction ID, Registered Office

**practitioners columns:** Transaction ID, Form Number, Company Number, Sequence, Name, Address Line 1–5

**free text columns:** Transaction ID, Form Number, Company Number, Sequence, Free Text

---

## 7. Sample data

Illustrative excerpts from a real daily extract (header/trailer and a few form groups). Trailing spaces on fixed fields are significant in the file; examples may show them trimmed in display.

### Header + first form groups

```
LIQNFORM427620260731
FMVL1       
RNNI037932
NACITYWATCH CCTV NORTHERN IRELAND                                                                     
DR30072026
FTSECURITY SYSTEMS SERVICE ACTIVITIES     
ID3535999865
FMRESS      
RNNI066056
NAGET FRESH (N.I.) LIMITED                                                                            
RD07072026
DR30072026
FT *** FORM REGISTERED IN ERROR ***
ID3536026189
```

### Form 600 (appointment + practitioners + free text)

```
FM600       
RN00777722
NAC.C.& R.J.EMERSON LIMITED                                                                           
NPJ A LOWE<UPPER MARLBOROUGH ROAD<ST ALBANS<AL1 3UU<<                                                 
NPM NEEDHAM<UPPER MARLBOROUGH ROAD<ST ALBANS<AL1 3UU<<                                                
AD09042026
DR21072026
FTFREIGHT TRANSPORT BY ROAD               
ID3534050140
```

### Court order style (`CO`)

```
FMCO        
CO00005999/2025
RN07436422
NARJ DEMOLITION LIMITED                                                                               
NPT O OR NOTTINGHAM<STATION STREET<NOTTINGHAM<NG2 3NG<<                                               
DO15072026
DP19082025
DR21072026
ID3534097625
```

### Scottish winding-up with registered office + multiple practitioners

```
FMWU01(SCOT)
CO0HAM L15/2026
RNSC811989
NAGIGGLES & GRINS UK LIMITED                                                                          
REROSEBERRY PLACE<<HAMILTON<<ML3 9EP<                                                                 
NPI MACNEIL<WEST GEORGE STREET<GLASGOW<G2 2LB<<                                                       
NPB W MILNE<WEST GEORGE STREET<GLASGOW<G2 2LB<<                                                       
DO30072026
DP30072026
DR30072026
ID3536072472
```

### Minimal LIQ13 / LIQ14 style

```
FMLIQ13     
RN02018903
NAR. & J. MARITIME LIMITED                                                                            
DR22072026
ID3534357598
FMLIQ14     
RN01539717
NAC J FREEMAN AND CO LIMITED                                                                          
DR21072026
ID3534073719
```

### Trailer

```
9999999900002215
```

(2,215 data records excluding header and trailer.)

---

## More info

- Official product: Companies House Liquidation Database bulk data (Product 197).
- Related implemented products in this repo: [Prod195_Snapshot.md](Prod195_Snapshot.md), [Prod198_Update.md](Prod198_Update.md), [Prod192_Disqualifications.md](Prod192_Disqualifications.md).
